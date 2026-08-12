import Foundation

public enum BadmintonWorkoutStoreError: Error, Equatable, Sendable {
    case workoutAlreadyExists(UUID)
    case workoutNotFound(UUID)
}

/// Atomic, one-file-per-workout storage. Metric updates are intentionally
/// checkpointed during the workout instead of existing only in memory.
public actor BadmintonWorkoutFileStore {
    public static let recordFileName = "workout.json"

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

    public func create(_ record: BadmintonWorkoutRecord) throws {
        try record.validate()
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        let directory = workoutDirectory(for: record.id)
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw BadmintonWorkoutStoreError.workoutAlreadyExists(record.id)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try write(record)
    }

    public func save(_ record: BadmintonWorkoutRecord) throws {
        guard fileManager.fileExists(atPath: workoutDirectory(for: record.id).path) else {
            throw BadmintonWorkoutStoreError.workoutNotFound(record.id)
        }
        try record.validate()
        try write(record)
    }

    public func load(id: UUID) throws -> BadmintonWorkoutRecord {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw BadmintonWorkoutStoreError.workoutNotFound(id)
        }
        return try decoder.decode(BadmintonWorkoutRecord.self, from: Data(contentsOf: url))
    }

    public func list() throws -> [BadmintonWorkoutRecord] {
        guard fileManager.fileExists(atPath: baseDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .map { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try load(id: id)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    public func unfinished() throws -> [BadmintonWorkoutRecord] {
        try list().filter {
            [.starting, .active, .paused].contains($0.lifecycleState)
        }
    }

    public func recoverUnfinished(
        at recoveredAt: Date = Date(),
        excluding excludedIDs: Set<UUID> = []
    ) throws -> [BadmintonWorkoutRecord] {
        let unfinished = try unfinished().filter { !excludedIDs.contains($0.id) }
        return try unfinished.map { existing in
            var recovered = existing
            // Only time that was checkpointed before termination is known to
            // be real active time. Using the relaunch date would overcount a
            // workout when the app remains closed for minutes or overnight.
            recovered.markInterrupted(
                at: min(
                    max(recoveredAt, existing.startedAt),
                    max(existing.updatedAt, existing.startedAt)
                ),
                failure: .init(
                    code: "unexpected_termination",
                    message: "Workout was recovered after an unexpected termination."
                )
            )
            try write(recovered)
            return recovered
        }
    }

    private func workoutDirectory(for id: UUID) -> URL {
        baseDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func recordURL(for id: UUID) -> URL {
        workoutDirectory(for: id).appendingPathComponent(Self.recordFileName)
    }

    private func write(_ record: BadmintonWorkoutRecord) throws {
        try encoder.encode(record).write(to: recordURL(for: record.id), options: [.atomic])
    }
}
