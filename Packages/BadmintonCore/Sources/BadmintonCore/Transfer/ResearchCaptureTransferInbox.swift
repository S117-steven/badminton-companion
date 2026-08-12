import Foundation

public struct ResearchCaptureTransferMetadata: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let schemaVersion: Int
    public let kind: ResearchCaptureStoredFileKind
    public let byteCount: Int64

    public init(
        captureID: UUID,
        schemaVersion: Int,
        kind: ResearchCaptureStoredFileKind,
        byteCount: Int64
    ) {
        self.captureID = captureID
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.byteCount = byteCount
    }
}

public enum ResearchCaptureInboxResult: Equatable, Sendable {
    case awaitingRemainingFile(UUID)
    case imported(UUID)
    case duplicate(UUID)
}

public enum ResearchCaptureInboxError: Error, Equatable, Sendable {
    case byteCountMismatch(expected: Int64, actual: Int64)
    case manifestIdentityMismatch
    case unsupportedSchemaVersion(Int)
}

/// Receives manifest and sample files independently, then imports only after
/// both parts are present and consistent. A WatchConnectivity adapter can feed
/// this inbox without changing the persistence rules.
public actor ResearchCaptureTransferInbox {
    private let inboxDirectory: URL
    private let destinationStore: ResearchCaptureFileStore
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    public init(
        inboxDirectory: URL,
        destinationStore: ResearchCaptureFileStore,
        fileManager: FileManager = .default
    ) {
        self.inboxDirectory = inboxDirectory
        self.destinationStore = destinationStore
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func receive(
        fileAt sourceURL: URL,
        metadata: ResearchCaptureTransferMetadata
    ) async throws -> ResearchCaptureInboxResult {
        guard metadata.schemaVersion <= ResearchCaptureManifest.currentSchemaVersion else {
            throw ResearchCaptureInboxError.unsupportedSchemaVersion(metadata.schemaVersion)
        }

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let actualByteCount = Int64(values.fileSize ?? 0)
        guard actualByteCount == metadata.byteCount else {
            throw ResearchCaptureInboxError.byteCountMismatch(
                expected: metadata.byteCount,
                actual: actualByteCount
            )
        }

        let captureInbox = inboxDirectory.appendingPathComponent(
            metadata.captureID.uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: captureInbox,
            withIntermediateDirectories: true
        )
        let destinationURL = captureInbox.appendingPathComponent(
            metadata.kind == .manifest
                ? ResearchCaptureFileStore.manifestFileName
                : ResearchCaptureFileStore.samplesFileName
        )
        let temporaryURL = captureInbox.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).incoming"
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }

        let manifestURL = captureInbox.appendingPathComponent(
            ResearchCaptureFileStore.manifestFileName
        )
        let samplesURL = captureInbox.appendingPathComponent(
            ResearchCaptureFileStore.samplesFileName
        )
        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: samplesURL.path) else {
            return .awaitingRemainingFile(metadata.captureID)
        }

        let manifest = try decoder.decode(
            ResearchCaptureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.id == metadata.captureID,
              manifest.schemaVersion == metadata.schemaVersion else {
            throw ResearchCaptureInboxError.manifestIdentityMismatch
        }

        let result = try await destinationStore.importCapture(
            manifest: manifest,
            samplesFileURL: samplesURL
        )
        try fileManager.removeItem(at: captureInbox)
        switch result {
        case .imported(let captureID):
            return .imported(captureID)
        case .duplicate(let captureID):
            return .duplicate(captureID)
        }
    }
}
