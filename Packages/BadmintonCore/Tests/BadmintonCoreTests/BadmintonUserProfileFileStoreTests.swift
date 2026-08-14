import XCTest
@testable import BadmintonCore

final class BadmintonUserProfileFileStoreTests: XCTestCase {
    func testOptionalProfileRoundTripDoesNotInventRequiredFields() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonUserProfileFileStore(directory: root)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = BadmintonUserProfile(
            heightCentimeters: 175,
            armSpanCentimeters: nil,
            skillLevelCode: "product_v1_regular",
            onboardingCompleted: true,
            updatedAt: updatedAt
        )

        try await store.save(profile)
        let loaded = try await store.load()

        XCTAssertEqual(loaded, profile)
        XCTAssertNil(loaded?.armSpanCentimeters)
    }

    func testInvalidPhysicalAndCalibrationMetadataIsRejected() async {
        let store = BadmintonUserProfileFileStore(directory: temporaryRoot())
        var profile = BadmintonUserProfile(heightCentimeters: -.infinity)

        await XCTAssertThrowsErrorAsync(try await store.save(profile)) { error in
            XCTAssertEqual(
                error as? BadmintonUserProfileValidationError,
                .invalidHeight
            )
        }

        profile = BadmintonUserProfile(
            calibrationCompletedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        await XCTAssertThrowsErrorAsync(try await store.save(profile)) { error in
            XCTAssertEqual(
                error as? BadmintonUserProfileValidationError,
                .incompleteCalibrationMetadata
            )
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
