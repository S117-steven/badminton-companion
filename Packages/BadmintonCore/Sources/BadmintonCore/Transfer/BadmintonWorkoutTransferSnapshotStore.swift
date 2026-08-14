import Foundation

/// Gives background transfer an immutable file whose lifetime is independent
/// from the source workout directory.
public actor BadmintonWorkoutTransferSnapshotStore {
    private let baseDirectory: URL
    private let fileManager: FileManager

    public init(baseDirectory: URL, fileManager: FileManager = .default) {
        self.baseDirectory = baseDirectory
        self.fileManager = fileManager
    }

    public func createSnapshot(
        for request: BadmintonWorkoutTransferRequest
    ) throws -> BadmintonWorkoutTransferRequest {
        let directory = baseDirectory
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destination = directory.appendingPathComponent(
                BadmintonWorkoutFileStore.recordFileName
            )
            try fileManager.copyItem(at: request.file.url, to: destination)
            let values = try destination.resourceValues(forKeys: [.fileSizeKey])
            return .init(
                workoutID: request.workoutID,
                schemaVersion: request.schemaVersion,
                file: .init(
                    workoutID: request.workoutID,
                    url: destination,
                    byteCount: Int64(values.fileSize ?? 0)
                )
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func removeSnapshotFile(at url: URL) {
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL
                == baseDirectory.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }
}
