import XCTest
@testable import BadmintonCore

final class ResearchCaptureNDJSONExporterTests: XCTestCase {
    func testExportKeepsHeaderMetadataAndRawSampleLines() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let captureStore = ResearchCaptureFileStore(
            baseDirectory: root.appendingPathComponent("Captures", isDirectory: true)
        )
        let participantStore = ResearchParticipantFileStore(
            baseDirectory: root.appendingPathComponent("Participants", isDirectory: true)
        )
        let participantDate = Date(timeIntervalSince1970: 1_700_000_000)
        let participant = ResearchParticipant(
            heightCentimeters: 175,
            armSpanCentimeters: 177,
            skillLevelCode: "research_v1_regular",
            createdAt: participantDate,
            updatedAt: participantDate
        )
        try await participantStore.save(participant)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = ResearchCaptureManifest(
            participantID: participant.id,
            mode: .singleAction,
            manualLabel: .smash,
            provenance: .automatedTestFixture,
            startedAt: startedAt,
            device: .init(
                hardwareModel: "test-watch",
                operatingSystemVersion: "test-os",
                applicationVersion: "0.1.0",
                applicationBuild: "1"
            )
        )
        try await captureStore.createCapture(manifest)
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
        _ = try await captureStore.append(samples, to: manifest.id)
        _ = try await captureStore.finishCapture(
            captureID: manifest.id,
            endedAt: startedAt.addingTimeInterval(1),
            quality: .init()
        )

        let destination = root.appendingPathComponent("capture.badminton-ndjson")
        let result = try await ResearchCaptureNDJSONExporter(
            captureStore: captureStore,
            participantStore: participantStore
        ).export(
            captureID: manifest.id,
            to: destination,
            exportedAt: startedAt.addingTimeInterval(2)
        )

        let lines = try Data(contentsOf: destination).split(separator: 0x0A)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(
            ResearchCaptureExportHeader.self,
            from: Data(lines[0])
        )
        let restoredSamples = try lines.dropFirst().map {
            try decoder.decode(ResearchMotionSample.self, from: Data($0))
        }

        XCTAssertEqual(result.sampleCount, 2)
        XCTAssertTrue(result.includesParticipant)
        XCTAssertGreaterThan(result.byteCount, 0)
        XCTAssertEqual(header.manifest.id, manifest.id)
        XCTAssertEqual(header.participant, participant)
        XCTAssertEqual(restoredSamples, samples)
    }

    func testBatchExportPublishesAllFilesOnlyAfterCompletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let captureStore = ResearchCaptureFileStore(
            baseDirectory: root.appendingPathComponent("Captures", isDirectory: true)
        )
        let participantStore = ResearchParticipantFileStore(
            baseDirectory: root.appendingPathComponent("Participants", isDirectory: true)
        )
        let participant = ResearchParticipant(
            heightCentimeters: 175,
            armSpanCentimeters: 177,
            skillLevelCode: "research_v1_regular"
        )
        try await participantStore.save(participant)
        var captureIDs: [UUID] = []
        for offset in 0..<2 {
            let manifest = ResearchCaptureManifest(
                participantID: participant.id,
                mode: .singleAction,
                manualLabel: .smash,
                provenance: .automatedTestFixture,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
                device: .init(
                    hardwareModel: "test-watch",
                    operatingSystemVersion: "test-os",
                    applicationVersion: "0.1.0",
                    applicationBuild: "1"
                )
            )
            try await captureStore.createCapture(manifest)
            _ = try await captureStore.append(
                [
                    .init(
                        sequenceNumber: 0,
                        source: .accelerometer,
                        monotonicTimestampSeconds: Double(offset),
                        elapsedTimeSeconds: 0,
                        accelerationMetersPerSecondSquared: .init(x: 1, y: 2, z: 3)
                    ),
                ],
                to: manifest.id
            )
            _ = try await captureStore.finishCapture(
                captureID: manifest.id,
                endedAt: manifest.startedAt.addingTimeInterval(1),
                quality: .init()
            )
            captureIDs.append(manifest.id)
        }
        let destination = root.appendingPathComponent("batch", isDirectory: true)

        let result = try await ResearchCaptureNDJSONExporter(
            captureStore: captureStore,
            participantStore: participantStore
        ).exportBatch(
            captureIDs: captureIDs,
            to: destination,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.totalSampleCount, 2)
        XCTAssertTrue(result.files.allSatisfy {
            FileManager.default.fileExists(atPath: $0.fileURL.path)
        })
        XCTAssertTrue(result.files.allSatisfy(\.includesParticipant))
    }
}
