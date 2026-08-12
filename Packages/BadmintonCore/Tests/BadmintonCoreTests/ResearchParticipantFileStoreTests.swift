import XCTest
@testable import BadmintonCore

final class ResearchParticipantFileStoreTests: XCTestCase {
    func testParticipantRoundTripKeepsVersionedSkillMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchParticipantFileStore(baseDirectory: root)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let participant = ResearchParticipant(
            heightCentimeters: 178,
            armSpanCentimeters: 181,
            skillLevelCode: "research_v1_intermediate",
            skillLevelDefinitionVersion: 1,
            createdAt: timestamp,
            updatedAt: timestamp
        )

        try await store.save(participant)
        let restored = try await store.load(id: participant.id)
        let listed = try await store.list()

        XCTAssertEqual(restored, participant)
        XCTAssertEqual(listed, [participant])
    }

    func testParticipantRejectsMissingPhysicalMetadata() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ResearchParticipantFileStore(baseDirectory: root)
        let participant = ResearchParticipant(
            heightCentimeters: 0,
            armSpanCentimeters: 180,
            skillLevelCode: "research_v1_intermediate"
        )

        do {
            try await store.save(participant)
            XCTFail("Expected validation to fail")
        } catch {
            XCTAssertEqual(
                error as? ResearchParticipantValidationError,
                .invalidHeight
            )
        }
    }
}
