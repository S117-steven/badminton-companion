import XCTest
@testable import BadmintonCore

final class ResearchCaptureSessionCoordinatorTests: XCTestCase {
    func testSessionPersistsBatchesAndCompletesWithQualitySummary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchCaptureFileStore(baseDirectory: root)
        let coordinator = try ResearchCaptureSessionCoordinator(
            store: store,
            flushBatchSize: 2
        )
        let source = ControlledMotionSource(provenance: .automatedTestFixture)
        let manifest = makeManifest(provenance: .automatedTestFixture)

        _ = try await coordinator.start(
            manifest: manifest,
            source: source,
            configuration: .init(requestedIntervalSeconds: 0.01)
        )
        await source.emit([
            makeSample(sequence: 0, elapsed: 0, interval: nil),
            makeSample(sequence: 1, elapsed: 0.01, interval: 0.01),
            makeSample(sequence: 2, elapsed: 0.02, interval: 0.012),
        ])

        try await waitUntil {
            await coordinator.currentSnapshot().persistedSampleCount == 3
        }
        let completed = try await coordinator.stop(
            at: manifest.startedAt.addingTimeInterval(1)
        )
        let restored = try await store.loadManifest(captureID: manifest.id)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.receivedSampleCount, 3)
        XCTAssertEqual(completed.persistedSampleCount, 3)
        XCTAssertEqual(restored.state, .completed)
        XCTAssertEqual(restored.provenance, .automatedTestFixture)
        XCTAssertEqual(restored.quality.requestedIntervalSeconds, 0.01)
        XCTAssertEqual(restored.quality.averageActualIntervalSeconds, 0.011)
        XCTAssertEqual(restored.quality.maximumActualIntervalSeconds, 0.012)
    }

    func testSessionRejectsSourceWhoseProvenanceDoesNotMatchManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let coordinator = try ResearchCaptureSessionCoordinator(
            store: .init(baseDirectory: root)
        )
        let source = ControlledMotionSource(provenance: .simulatorSynthetic)

        do {
            _ = try await coordinator.start(
                manifest: makeManifest(provenance: .physicalSensor),
                source: source,
                configuration: .init(requestedIntervalSeconds: 0.01)
            )
            XCTFail("Expected provenance mismatch")
        } catch {
            XCTAssertEqual(
                error as? ResearchCaptureSessionError,
                .provenanceMismatch
            )
        }
    }

    func testSourceFailureProducesInterruptedRecoverableCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchCaptureFileStore(baseDirectory: root)
        let coordinator = try ResearchCaptureSessionCoordinator(
            store: store,
            flushBatchSize: 10
        )
        let source = ControlledMotionSource(provenance: .automatedTestFixture)
        let manifest = makeManifest(provenance: .automatedTestFixture)

        _ = try await coordinator.start(
            manifest: manifest,
            source: source,
            configuration: .init(requestedIntervalSeconds: 0.01)
        )
        await source.emit([makeSample(sequence: 0, elapsed: 0, interval: nil)])
        await source.fail(code: "sensor_unavailable", message: "Lost source")

        try await waitUntil {
            await coordinator.currentSnapshot().phase == .failed
        }
        let snapshot = await coordinator.currentSnapshot()
        let restored = try await store.loadManifest(captureID: manifest.id)

        XCTAssertEqual(snapshot.failure?.code, "sensor_unavailable")
        XCTAssertEqual(restored.state, .interrupted)
        XCTAssertEqual(restored.sampleCount, 1)
    }

    func testCreateConflictDoesNotMutateExistingCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchCaptureFileStore(baseDirectory: root)
        let manifest = makeManifest(provenance: .automatedTestFixture)
        try await store.createCapture(manifest)
        let coordinator = try ResearchCaptureSessionCoordinator(store: store)

        do {
            _ = try await coordinator.start(
                manifest: manifest,
                source: ControlledMotionSource(provenance: .automatedTestFixture),
                configuration: .init(requestedIntervalSeconds: 0.01)
            )
            XCTFail("Expected duplicate capture failure")
        } catch {
            XCTAssertEqual(
                error as? ResearchCaptureStoreError,
                .captureAlreadyExists(manifest.id)
            )
        }

        let existing = try await store.loadManifest(captureID: manifest.id)
        XCTAssertEqual(existing.state, .collecting)
        XCTAssertEqual(existing.sampleCount, 0)
        XCTAssertNil(existing.endedAt)
    }

    private func makeManifest(
        provenance: ResearchDataProvenance
    ) -> ResearchCaptureManifest {
        ResearchCaptureManifest(
            participantID: UUID(),
            mode: .singleAction,
            manualLabel: .normalShot,
            provenance: provenance,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )
    }

    private func makeSample(
        sequence: UInt64,
        elapsed: TimeInterval,
        interval: TimeInterval?
    ) -> ResearchMotionSample {
        ResearchMotionSample(
            sequenceNumber: sequence,
            source: .accelerometer,
            monotonicTimestampSeconds: 100 + elapsed,
            elapsedTimeSeconds: elapsed,
            actualIntervalSeconds: interval,
            accelerationMetersPerSecondSquared: .init(x: 1, y: 2, z: 3)
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for async state")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor ControlledMotionSource: ResearchMotionSource {
    nonisolated let provenance: ResearchDataProvenance
    private var handler: (@Sendable (ResearchMotionSourceEvent) -> Void)?

    init(provenance: ResearchDataProvenance) {
        self.provenance = provenance
    }

    func start(
        configuration: ResearchMotionSourceConfiguration,
        onEvent: @escaping @Sendable (ResearchMotionSourceEvent) -> Void
    ) async throws {
        handler = onEvent
    }

    func stop() async {
        handler = nil
    }

    func emit(_ samples: [ResearchMotionSample]) {
        handler?(.samples(samples))
    }

    func fail(code: String, message: String) {
        handler?(.failure(.init(code: code, message: message)))
    }
}
