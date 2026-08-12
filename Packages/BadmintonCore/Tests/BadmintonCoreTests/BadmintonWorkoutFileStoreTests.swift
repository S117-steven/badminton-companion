import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutFileStoreTests: XCTestCase {
    func testRoundTripAndRecoveryPreserveAUsableInterruptedCheckpoint() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var record = makeRecord(start: start)
        record.markStarted(at: start)
        record.checkpointActiveDuration(at: start.addingTimeInterval(10))
        try await store.create(record)

        let recovered = try await store.recoverUnfinished(
            at: start.addingTimeInterval(86_400)
        )
        let restored = try await store.load(id: record.id)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(restored.lifecycleState, .interrupted)
        XCTAssertEqual(restored.accumulatedActiveDurationSeconds, 10)
        XCTAssertEqual(restored.healthWriteState, .simulatedNotSaved)
        XCTAssertEqual(restored.failureCode, "unexpected_termination")
        XCTAssertNoThrow(try restored.validate())
    }

    func testDuplicateWorkoutDoesNotOverwriteExistingCheckpoint() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let record = makeRecord(start: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.create(record)

        do {
            try await store.create(record)
            XCTFail("Expected duplicate workout error")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutStoreError,
                .workoutAlreadyExists(record.id)
            )
        }
        let restored = try await store.load(id: record.id)
        XCTAssertEqual(restored, record)
    }

    private func makeRecord(start: Date) -> BadmintonWorkoutRecord {
        .init(
            provenance: .simulatorSynthetic,
            startedAt: start,
            healthAuthorizationState: .simulated
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
