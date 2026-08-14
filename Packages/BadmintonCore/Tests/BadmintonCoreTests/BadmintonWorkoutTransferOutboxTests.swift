import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutTransferOutboxTests: XCTestCase {
    func testOnlyTerminalWorkoutsQueueRetryAndAcknowledgeMonotonically() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workoutStore = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("workouts", isDirectory: true)
        )
        let stateStore = BadmintonWorkoutTransferStateStore(
            baseDirectory: root.appendingPathComponent("states", isDirectory: true)
        )
        let outbox = BadmintonWorkoutTransferOutbox(
            workoutStore: workoutStore,
            stateStore: stateStore
        )
        let active = makeActiveRecord(id: UUID())
        let completed = makeCompletedRecord(id: UUID())
        try await workoutStore.create(active)
        try await workoutStore.create(completed)

        let requests = try await outbox.pendingRequests()
        XCTAssertEqual(requests.map(\.workoutID), [completed.id])

        let enqueued = try await outbox.markEnqueued(
            workoutID: completed.id,
            schemaVersion: completed.schemaVersion
        )
        XCTAssertEqual(enqueued.state, .transferred)
        let awaitingAcknowledgement = try await outbox.pendingRequests()
        XCTAssertEqual(awaitingAcknowledgement.count, 1)

        let retry = try await outbox.markForRetry(
            workoutID: completed.id,
            schemaVersion: completed.schemaVersion
        )
        XCTAssertEqual(retry.state, .pendingTransfer)

        let acknowledgement = BadmintonWorkoutTransferAcknowledgement(
            workoutID: completed.id,
            schemaVersion: completed.schemaVersion
        )
        let acknowledged = try await outbox.acknowledge(acknowledgement)
        XCTAssertEqual(acknowledged.state, .acknowledged)
        let remaining = try await outbox.pendingRequests()
        XCTAssertTrue(remaining.isEmpty)

        let repeated = try await outbox.acknowledge(acknowledgement)
        XCTAssertEqual(repeated.state, .acknowledged)
        do {
            _ = try await outbox.request(workoutID: active.id)
            XCTFail("Active workout must not transfer")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutTransferOutboxError,
                .workoutNotTerminal(active.id, .active)
            )
        }
    }

    func testSnapshotAndPropertyListRemainStableAcrossRetry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let workoutStore = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("workouts", isDirectory: true)
        )
        let stateStore = BadmintonWorkoutTransferStateStore(
            baseDirectory: root.appendingPathComponent("states", isDirectory: true)
        )
        let outbox = BadmintonWorkoutTransferOutbox(
            workoutStore: workoutStore,
            stateStore: stateStore
        )
        let snapshots = BadmintonWorkoutTransferSnapshotStore(
            baseDirectory: root.appendingPathComponent("snapshots", isDirectory: true)
        )
        var record = makeCompletedRecord(id: UUID())
        try await workoutStore.create(record)
        let request = try await outbox.request(workoutID: record.id)
        let snapshot = try await snapshots.createSnapshot(for: request)
        let originalBytes = try Data(contentsOf: snapshot.file.url)

        record.healthMetrics.averageHeartRateBeatsPerMinute = 135
        record.healthMetrics.maximumHeartRateBeatsPerMinute = 172
        try await workoutStore.save(record)

        XCTAssertEqual(try Data(contentsOf: snapshot.file.url), originalBytes)
        let metadata = BadmintonWorkoutTransferMetadata(
            workoutID: snapshot.workoutID,
            schemaVersion: snapshot.schemaVersion,
            byteCount: snapshot.file.byteCount
        )
        XCTAssertEqual(
            try BadmintonWorkoutTransferPropertyListCodec.decodeMetadata(
                BadmintonWorkoutTransferPropertyListCodec.encode(metadata: metadata)
            ),
            metadata
        )
        let acknowledgement = BadmintonWorkoutTransferAcknowledgement(
            workoutID: record.id,
            schemaVersion: record.schemaVersion
        )
        XCTAssertEqual(
            try BadmintonWorkoutTransferPropertyListCodec.decodeAcknowledgement(
                BadmintonWorkoutTransferPropertyListCodec.encode(
                    acknowledgement: acknowledgement
                )
            ),
            acknowledgement
        )
        await snapshots.removeSnapshotFile(at: snapshot.file.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.file.url.path))
    }

    private func makeActiveRecord(id: UUID) -> BadmintonWorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(
            id: id,
            provenance: .automatedTestFixture,
            startedAt: start,
            lifecycleState: .active,
            lastResumedAt: start,
            healthAuthorizationState: .simulated,
            updatedAt: start
        )
    }

    private func makeCompletedRecord(id: UUID) -> BadmintonWorkoutRecord {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return .init(
            id: id,
            provenance: .automatedTestFixture,
            startedAt: start,
            endedAt: start.addingTimeInterval(900),
            lifecycleState: .completed,
            accumulatedActiveDurationSeconds: 840,
            healthAuthorizationState: .simulated,
            healthWriteState: .simulatedNotSaved,
            updatedAt: start.addingTimeInterval(900)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
