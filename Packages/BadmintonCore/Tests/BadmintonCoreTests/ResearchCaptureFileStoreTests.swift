import XCTest
@testable import BadmintonCore

final class ResearchCaptureFileStoreTests: XCTestCase {
    func testCaptureRoundTripPreservesRawSamplesAndHumanLabel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchCaptureFileStore(baseDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .singleAction,
            manualLabel: .smash,
            startedAt: startedAt,
            device: ResearchDeviceMetadata(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )

        try await store.createCapture(manifest)
        let samples = [
            ResearchMotionSample(
                sequenceNumber: 0,
                source: .accelerometer,
                monotonicTimestampSeconds: 100,
                elapsedTimeSeconds: 0,
                accelerationMetersPerSecondSquared: .init(x: 1, y: 2, z: 3)
            ),
            ResearchMotionSample(
                sequenceNumber: 1,
                source: .gyroscope,
                monotonicTimestampSeconds: 100.01,
                elapsedTimeSeconds: 0.01,
                actualIntervalSeconds: 0.01,
                angularVelocityRadiansPerSecond: .init(x: 4, y: 5, z: 6)
            ),
        ]

        _ = try await store.append(samples, to: manifest.id)
        let finished = try await store.finishCapture(
            captureID: manifest.id,
            endedAt: startedAt.addingTimeInterval(1),
            quality: .init(
                requestedIntervalSeconds: 0.01,
                averageActualIntervalSeconds: 0.01,
                maximumActualIntervalSeconds: 0.01
            )
        )

        let restoredSamples = try await store.loadSamples(captureID: manifest.id)
        XCTAssertEqual(restoredSamples, samples)
        XCTAssertEqual(finished.manualLabel, .smash)
        XCTAssertEqual(finished.sampleCount, 2)
        XCTAssertEqual(finished.state, .completed)
        XCTAssertEqual(finished.syncState, .pendingTransfer)
        XCTAssertNil(finished.externalSpeedReference)
    }

    func testDuplicateCaptureDoesNotOverwriteExistingData() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchCaptureFileStore(baseDirectory: root)
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .normalShotBatch,
            manualLabel: .normalShot,
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )

        try await store.createCapture(manifest)

        do {
            try await store.createCapture(manifest)
            XCTFail("Expected duplicate capture creation to fail")
        } catch {
            XCTAssertEqual(
                error as? ResearchCaptureStoreError,
                .captureAlreadyExists(manifest.id)
            )
        }
    }
}
