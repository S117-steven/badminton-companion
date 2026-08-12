import Foundation

public struct ResearchCaptureExportHeader: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let recordType: String
    public let formatVersion: Int
    public let exportedAt: Date
    public let manifest: ResearchCaptureManifest
    public let participant: ResearchParticipant?

    public init(
        formatVersion: Int = currentFormatVersion,
        exportedAt: Date,
        manifest: ResearchCaptureManifest,
        participant: ResearchParticipant?
    ) {
        recordType = "badminton_research_capture_header"
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.manifest = manifest
        self.participant = participant
    }
}

public struct ResearchCaptureExportResult: Equatable, Sendable {
    public let fileURL: URL
    public let sampleCount: Int
    public let includesParticipant: Bool
    public let byteCount: Int64

    public init(
        fileURL: URL,
        sampleCount: Int,
        includesParticipant: Bool,
        byteCount: Int64
    ) {
        self.fileURL = fileURL
        self.sampleCount = sampleCount
        self.includesParticipant = includesParticipant
        self.byteCount = byteCount
    }
}

/// Writes one script-friendly NDJSON file. The first line is a versioned header
/// containing manifest and optional participant metadata; every following line
/// is an unchanged raw `ResearchMotionSample` record.
public actor ResearchCaptureNDJSONExporter {
    private let captureStore: ResearchCaptureFileStore
    private let participantStore: ResearchParticipantFileStore
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    public init(
        captureStore: ResearchCaptureFileStore,
        participantStore: ResearchParticipantFileStore,
        fileManager: FileManager = .default
    ) {
        self.captureStore = captureStore
        self.participantStore = participantStore
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    public func export(
        captureID: UUID,
        to destinationURL: URL,
        exportedAt: Date = Date()
    ) async throws -> ResearchCaptureExportResult {
        let manifest = try await captureStore.loadManifest(captureID: captureID)
        let participant = try await loadParticipantIfPresent(id: manifest.participantID)
        let samplesFile = try await captureStore.storedFile(
            captureID: captureID,
            kind: .samples
        )
        let header = ResearchCaptureExportHeader(
            exportedAt: exportedAt,
            manifest: manifest,
            participant: participant
        )

        let parentDirectory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        let temporaryURL = parentDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).incoming"
        )
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let output = try FileHandle(forWritingTo: temporaryURL)
            defer { try? output.close() }
            var headerData = try encoder.encode(header)
            headerData.append(0x0A)
            try output.write(contentsOf: headerData)

            let input = try FileHandle(forReadingFrom: samplesFile.url)
            defer { try? input.close() }
            while true {
                let data = try input.read(upToCount: 64 * 1_024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let values = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
        return ResearchCaptureExportResult(
            fileURL: destinationURL,
            sampleCount: manifest.sampleCount,
            includesParticipant: participant != nil,
            byteCount: Int64(values.fileSize ?? 0)
        )
    }

    private func loadParticipantIfPresent(id: UUID) async throws -> ResearchParticipant? {
        do {
            return try await participantStore.load(id: id)
        } catch let error as ResearchParticipantStoreError {
            guard error == .participantNotFound(id) else { throw error }
            return nil
        }
    }
}
