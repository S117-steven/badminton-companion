import XCTest
@testable import BadmintonCore

final class ResearchCaptureTransferInboxTests: XCTestCase {
    func testInboxWaitsForBothFilesThenImportsIdempotently() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outgoing = ResearchCaptureFileStore(
            baseDirectory: root.appendingPathComponent("outgoing")
        )
        let incoming = ResearchCaptureFileStore(
            baseDirectory: root.appendingPathComponent("received")
        )
        let inbox = ResearchCaptureTransferInbox(
            inboxDirectory: root.appendingPathComponent("inbox"),
            destinationStore: incoming
        )
        let manifest = makeManifest()
        try await outgoing.createCapture(manifest)
        _ = try await outgoing.append([makeSample()], to: manifest.id)
        let completed = try await outgoing.finishCapture(
            captureID: manifest.id,
            endedAt: manifest.startedAt.addingTimeInterval(1),
            quality: .init(requestedIntervalSeconds: 0.01)
        )

        let manifestFile = try await outgoing.storedFile(
            captureID: manifest.id,
            kind: .manifest
        )
        let samplesFile = try await outgoing.storedFile(
            captureID: manifest.id,
            kind: .samples
        )

        let first = try await inbox.receive(
            fileAt: manifestFile.url,
            metadata: metadata(for: manifestFile, schemaVersion: completed.schemaVersion)
        )
        XCTAssertEqual(first, .awaitingRemainingFile(manifest.id))

        let second = try await inbox.receive(
            fileAt: samplesFile.url,
            metadata: metadata(for: samplesFile, schemaVersion: completed.schemaVersion)
        )
        XCTAssertEqual(second, .imported(manifest.id))

        _ = try await inbox.receive(
            fileAt: manifestFile.url,
            metadata: metadata(for: manifestFile, schemaVersion: completed.schemaVersion)
        )
        let duplicate = try await inbox.receive(
            fileAt: samplesFile.url,
            metadata: metadata(for: samplesFile, schemaVersion: completed.schemaVersion)
        )
        XCTAssertEqual(duplicate, .duplicate(manifest.id))

        let restored = try await incoming.loadManifest(captureID: manifest.id)
        let samples = try await incoming.loadSamples(captureID: manifest.id)
        XCTAssertEqual(restored, completed)
        XCTAssertEqual(samples, [makeSample()])
    }

    func testInboxRejectsIncorrectTransferByteCount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("manifest.json")
        try Data("{}".utf8).write(to: file)

        let inbox = ResearchCaptureTransferInbox(
            inboxDirectory: root.appendingPathComponent("inbox"),
            destinationStore: .init(
                baseDirectory: root.appendingPathComponent("received")
            )
        )
        let captureID = UUID()
        do {
            _ = try await inbox.receive(
                fileAt: file,
                metadata: .init(
                    captureID: captureID,
                    schemaVersion: ResearchCaptureManifest.currentSchemaVersion,
                    kind: .manifest,
                    byteCount: 999
                )
            )
            XCTFail("Expected byte count mismatch")
        } catch {
            XCTAssertEqual(
                error as? ResearchCaptureInboxError,
                .byteCountMismatch(expected: 999, actual: 2)
            )
        }
    }

    private func metadata(
        for file: ResearchCaptureStoredFile,
        schemaVersion: Int
    ) -> ResearchCaptureTransferMetadata {
        .init(
            captureID: file.captureID,
            schemaVersion: schemaVersion,
            kind: file.kind,
            byteCount: file.byteCount
        )
    }

    private func makeManifest() -> ResearchCaptureManifest {
        ResearchCaptureManifest(
            participantID: UUID(),
            mode: .singleAction,
            manualLabel: .normalShot,
            provenance: .automatedTestFixture,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )
    }

    private func makeSample() -> ResearchMotionSample {
        .init(
            sequenceNumber: 0,
            source: .accelerometer,
            monotonicTimestampSeconds: 100,
            elapsedTimeSeconds: 0,
            accelerationMetersPerSecondSquared: .init(x: 1, y: 2, z: 3)
        )
    }
}
