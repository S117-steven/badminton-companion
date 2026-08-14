import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutTransferInboxTests: XCTestCase {
    func testImportIsAtomicIdempotentAndRejectsConflictingFacts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoing = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("outgoing", isDirectory: true)
        )
        let incoming = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("incoming", isDirectory: true)
        )
        let inbox = BadmintonWorkoutTransferInbox(
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
            destinationStore: incoming
        )
        let record = makeCompletedRecord(id: UUID(), activeEnergy: 120)
        try await outgoing.create(record)
        let file = try await outgoing.storedFile(id: record.id)
        let metadata = BadmintonWorkoutTransferMetadata(
            workoutID: record.id,
            schemaVersion: record.schemaVersion,
            byteCount: file.byteCount
        )

        let imported = try await inbox.receive(fileAt: file.url, metadata: metadata)
        XCTAssertEqual(imported, .imported(record.id))
        let duplicate = try await inbox.receive(fileAt: file.url, metadata: metadata)
        XCTAssertEqual(duplicate, .duplicate(record.id))

        let conflictingStore = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("conflict", isDirectory: true)
        )
        let conflicting = makeCompletedRecord(id: record.id, activeEnergy: 999)
        try await conflictingStore.create(conflicting)
        let conflictFile = try await conflictingStore.storedFile(id: record.id)
        do {
            _ = try await inbox.receive(
                fileAt: conflictFile.url,
                metadata: .init(
                    workoutID: record.id,
                    schemaVersion: record.schemaVersion,
                    byteCount: conflictFile.byteCount
                )
            )
            XCTFail("Conflicting watch facts must not overwrite phone history")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutStoreError,
                .workoutConflict(record.id)
            )
        }
        let restored = try await incoming.load(id: record.id)
        XCTAssertEqual(restored, record)
    }

    func testByteCountAndIdentityMustMatchBeforeImport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoing = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("outgoing", isDirectory: true)
        )
        let incoming = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("incoming", isDirectory: true)
        )
        let inbox = BadmintonWorkoutTransferInbox(
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
            destinationStore: incoming
        )
        let record = makeCompletedRecord(id: UUID(), activeEnergy: 120)
        try await outgoing.create(record)
        let file = try await outgoing.storedFile(id: record.id)

        do {
            _ = try await inbox.receive(
                fileAt: file.url,
                metadata: .init(
                    workoutID: record.id,
                    schemaVersion: record.schemaVersion,
                    byteCount: file.byteCount + 1
                )
            )
            XCTFail("Incorrect byte count must fail")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutInboxError,
                .byteCountMismatch(
                    expected: file.byteCount + 1,
                    actual: file.byteCount
                )
            )
        }

        do {
            _ = try await inbox.receive(
                fileAt: file.url,
                metadata: .init(
                    workoutID: UUID(),
                    schemaVersion: record.schemaVersion,
                    byteCount: file.byteCount
                )
            )
            XCTFail("Mismatched workout identity must fail")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutInboxError,
                .recordIdentityMismatch
            )
        }
        let importedRecords = try await incoming.list()
        XCTAssertTrue(importedRecords.isEmpty)
    }

    func testNonterminalAndUnsupportedRecordsNeverEnterPhoneHistory() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outgoing = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("outgoing", isDirectory: true)
        )
        let incoming = BadmintonWorkoutFileStore(
            baseDirectory: root.appendingPathComponent("incoming", isDirectory: true)
        )
        let inbox = BadmintonWorkoutTransferInbox(
            stagingDirectory: root.appendingPathComponent("staging", isDirectory: true),
            destinationStore: incoming
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let active = BadmintonWorkoutRecord(
            provenance: .automatedTestFixture,
            startedAt: start,
            lifecycleState: .active,
            lastResumedAt: start,
            healthAuthorizationState: .simulated,
            updatedAt: start
        )
        try await outgoing.create(active)
        let file = try await outgoing.storedFile(id: active.id)

        do {
            _ = try await inbox.receive(
                fileAt: file.url,
                metadata: .init(
                    workoutID: active.id,
                    schemaVersion: active.schemaVersion,
                    byteCount: file.byteCount
                )
            )
            XCTFail("Active workout must not enter phone history")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutInboxError,
                .workoutNotTerminal(.active)
            )
        }

        do {
            _ = try await inbox.receive(
                fileAt: file.url,
                metadata: .init(
                    workoutID: active.id,
                    schemaVersion: BadmintonWorkoutRecord.currentSchemaVersion + 1,
                    byteCount: file.byteCount
                )
            )
            XCTFail("Unsupported schema must not enter phone history")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutInboxError,
                .unsupportedSchemaVersion(
                    BadmintonWorkoutRecord.currentSchemaVersion + 1
                )
            )
        }
        let records = try await incoming.list()
        XCTAssertTrue(records.isEmpty)
    }

    private func makeCompletedRecord(
        id: UUID,
        activeEnergy: Double
    ) -> BadmintonWorkoutRecord {
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
            healthMetrics: .init(activeEnergyKilocalories: activeEnergy),
            lastMetricAt: start.addingTimeInterval(890),
            updatedAt: start.addingTimeInterval(900)
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
