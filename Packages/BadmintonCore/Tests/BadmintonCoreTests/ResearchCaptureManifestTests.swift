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

    func testSchemaTwoManifestRemainsReadableWithoutSourceSummaries() throws {
        let manifest = ResearchCaptureManifest(
            schemaVersion: 2,
            participantID: UUID(),
            mode: .normalShotBatch,
            manualLabel: .normalShot,
            provenance: .simulatorSynthetic,
            device: device,
            quality: .init(requestedIntervalSeconds: 0.02)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(
            ResearchCaptureManifest.self,
            from: encoder.encode(manifest)
        )

        XCTAssertEqual(restored.schemaVersion, 2)
        XCTAssertNil(restored.quality.sourceSummaries)
    }
}
