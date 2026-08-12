import Foundation

/// Creates immutable copies for background transports whose delivery can
/// outlive the source capture's next manifest update.
public actor ResearchCaptureTransferSnapshotStore {
    private let baseDirectory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func createSnapshot(
        for request: ResearchCaptureTransferRequest
    ) throws -> ResearchCaptureTransferRequest {
        let batchDirectory = baseDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: batchDirectory,
                withIntermediateDirectories: true
            )
            let files = try request.files.map { file in
                let fileName = switch file.kind {
                case .manifest: ResearchCaptureFileStore.manifestFileName
                case .samples: ResearchCaptureFileStore.samplesFileName
                }
                let destination = batchDirectory.appendingPathComponent(fileName)
                if file.kind == .manifest {
                    var manifest = try decoder.decode(
                        ResearchCaptureManifest.self,
                        from: Data(contentsOf: file.url)
                    )
                    manifest.syncState = .pendingTransfer
                    try encoder.encode(manifest).write(
                        to: destination,
                        options: .atomic
                    )
                } else {
                    try fileManager.copyItem(at: file.url, to: destination)
                }
                let values = try destination.resourceValues(forKeys: [.fileSizeKey])
                return ResearchCaptureStoredFile(
                    captureID: request.captureID,
                    kind: file.kind,
                    url: destination,
                    byteCount: Int64(values.fileSize ?? 0)
                )
            }
            return ResearchCaptureTransferRequest(
                captureID: request.captureID,
                schemaVersion: request.schemaVersion,
                files: files
            )
        } catch {
            try? fileManager.removeItem(at: batchDirectory)
            throw error
        }
    }

    public func removeSnapshotFile(at url: URL) {
        guard url.deletingLastPathComponent().deletingLastPathComponent()
            .standardizedFileURL == baseDirectory.standardizedFileURL else {
            return
        }
        let batchDirectory = url.deletingLastPathComponent()
        try? fileManager.removeItem(at: url)
        if let remaining = try? fileManager.contentsOfDirectory(
            at: batchDirectory,
            includingPropertiesForKeys: nil
        ), remaining.isEmpty {
            try? fileManager.removeItem(at: batchDirectory)
        }
    }
}
