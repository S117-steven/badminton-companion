import XCTest
@testable import BadmintonCore

final class ResearchCaptureTransferOutboxTests: XCTestCase {
    func testOutboxQueuesBothFilesRetriesAndAcknowledgesMonotonically() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchCaptureFileStore(baseDirectory: root)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .freePlay,
            manualLabel: nil,
            provenance: .automatedTestFixture,
            startedAt: startedAt,
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )
        try await store.createCapture(manifest)
        _ = try await store.append(
            [
                .init(
                    sequenceNumber: 0,
                    source: .accelerometer,
                    monotonicTimestampSeconds: 100,
                    elapsedTimeSeconds: 0,
                    accelerationMetersPerSecondSquared: .init(x: 1, y: 2, z: 3)
                ),
            ],
            to: manifest.id
        )
        _ = try await store.finishCapture(
            captureID: manifest.id,
            endedAt: startedAt.addingTimeInterval(1),
            quality: .init()
        )
        let outbox = ResearchCaptureTransferOutbox(store: store)

        let requests = try await outbox.pendingRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(Set(requests[0].files.map(\.kind)), [.manifest, .samples])
        XCTAssertTrue(requests[0].files.allSatisfy { $0.byteCount >= 0 })

        let enqueued = try await outbox.markEnqueued(captureID: manifest.id)
        XCTAssertEqual(enqueued.syncState, .transferred)
        let requestsAwaitingAcknowledgement = try await outbox.pendingRequests()
        XCTAssertEqual(requestsAwaitingAcknowledgement.count, 1)
        let retry = try await outbox.markForRetry(captureID: manifest.id)
        XCTAssertEqual(retry.syncState, .pendingTransfer)
        _ = try await outbox.markEnqueued(captureID: manifest.id)
        let acknowledged = try await outbox.acknowledge(
            .init(captureID: manifest.id, schemaVersion: manifest.schemaVersion)
        )
        XCTAssertEqual(acknowledged.syncState, .acknowledged)
        let remainingRequests = try await outbox.pendingRequests()
        XCTAssertTrue(remainingRequests.isEmpty)
        do {
            _ = try await outbox.request(captureID: manifest.id)
            XCTFail("Acknowledged capture must not be queued again")
        } catch {
            XCTAssertEqual(
                error as? ResearchCaptureTransferOutboxError,
                .captureNotTransferable(manifest.id, .acknowledged)
            )
        }
    }

    func testPropertyListCodecRoundTripsMetadataAndAcknowledgement() throws {
        let captureID = UUID()
        let metadata = ResearchCaptureTransferMetadata(
            captureID: captureID,
            schemaVersion: 3,
            kind: .samples,
            byteCount: 123_456
        )
        let acknowledgement = ResearchCaptureTransferAcknowledgement(
            captureID: captureID,
            schemaVersion: 3
        )

        XCTAssertEqual(
            try ResearchTransferPropertyListCodec.decodeMetadata(
                ResearchTransferPropertyListCodec.encode(metadata: metadata)
            ),
            metadata
        )
        XCTAssertEqual(
            try ResearchTransferPropertyListCodec.decodeAcknowledgement(
                ResearchTransferPropertyListCodec.encode(
                    acknowledgement: acknowledgement
                )
            ),
            acknowledgement
        )
    }

    func testTransferSnapshotRemainsStableWhenSourceManifestChanges() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ResearchCaptureFileStore(
            baseDirectory: root.appendingPathComponent("captures", isDirectory: true)
        )
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .freePlay,
            manualLabel: nil,
            provenance: .automatedTestFixture,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )
        try await store.createCapture(manifest)
        _ = try await store.finishCapture(
            captureID: manifest.id,
            endedAt: manifest.startedAt.addingTimeInterval(1),
            quality: .init()
        )
        let outbox = ResearchCaptureTransferOutbox(store: store)
        let snapshotStore = ResearchCaptureTransferSnapshotStore(
            baseDirectory: root.appendingPathComponent("outgoing", isDirectory: true)
        )
        let request = try await outbox.request(captureID: manifest.id)
        let snapshot = try await snapshotStore.createSnapshot(for: request)
        let snapshotManifest = try XCTUnwrap(
            snapshot.files.first { $0.kind == .manifest }
        )
        let bytesBeforeStateChange = try Data(contentsOf: snapshotManifest.url)

        _ = try await outbox.markEnqueued(captureID: manifest.id)
        let retryRequest = try await outbox.request(captureID: manifest.id)
        let retrySnapshot = try await snapshotStore.createSnapshot(for: retryRequest)
        let retryManifest = try XCTUnwrap(
            retrySnapshot.files.first { $0.kind == .manifest }
        )

        XCTAssertEqual(try Data(contentsOf: snapshotManifest.url), bytesBeforeStateChange)
        XCTAssertEqual(try Data(contentsOf: retryManifest.url), bytesBeforeStateChange)
        XCTAssertEqual(snapshotManifest.byteCount, Int64(bytesBeforeStateChange.count))
        await snapshotStore.removeSnapshotFile(at: snapshotManifest.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotManifest.url.path))
    }
}
