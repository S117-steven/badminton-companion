import XCTest
@testable import BadmintonCore

final class ResearchCaptureManifestTests: XCTestCase {
    private let device = ResearchDeviceMetadata(
        hardwareModel: "test-watch",
        operatingSystemVersion: "test-os",
        applicationVersion: "0.1.0",
        applicationBuild: "1"
    )

    func testFreePlayDoesNotAcceptSyntheticManualLabel() throws {
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .freePlay,
            manualLabel: .smash,
            provenance: .automatedTestFixture,
            device: device
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ResearchCaptureValidationError,
                .unexpectedManualLabelForFreePlay
            )
        }
    }

    func testBatchModeRequiresItsHumanSelectedFixedLabel() throws {
        let manifest = ResearchCaptureManifest(
            participantID: UUID(),
            mode: .smashBatch,
            manualLabel: .normalShot,
            provenance: .automatedTestFixture,
            device: device
        )

        XCTAssertThrowsError(try manifest.validate()) { error in
            XCTAssertEqual(
                error as? ResearchCaptureValidationError,
                .fixedLabelMismatch
            )
        }
    }
}
