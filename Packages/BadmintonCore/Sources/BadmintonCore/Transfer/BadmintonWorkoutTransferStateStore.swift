import Foundation

public enum BadmintonWorkoutSyncState: String, Codable, Equatable, Sendable {
    case pendingTransfer = "pending_transfer"
    case transferred
    case acknowledged
}

public struct BadmintonWorkoutTransferStatus: Codable, Equatable, Sendable {
    public let workoutID: UUID
    public let schemaVersion: Int
    public var state: BadmintonWorkoutSyncState
    public var updatedAt: Date

    public init(
        workoutID: UUID,
        schemaVersion: Int,
        state: BadmintonWorkoutSyncState,
        updatedAt: Date
    ) {
        self.workoutID = workoutID
        self.schemaVersion = schemaVersion
        self.state = state
        self.updatedAt = updatedAt
    }
}

public enum BadmintonWorkoutTransferStateError: Error, Equatable, Sendable {
    case schemaMismatch(expected: Int, actual: Int)
    case invalidTransition(
        from: BadmintonWorkoutSyncState,
        to: BadmintonWorkoutSyncState
    )
}

/// Keeps delivery state separate from immutable workout facts. This lets old
/// workout schema v1 files remain readable while transfer retries evolve.
public actor BadmintonWorkoutTransferStateStore {
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

    public func load(workoutID: UUID) throws -> BadmintonWorkoutTransferStatus? {
        let url = statusURL(for: workoutID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(
            BadmintonWorkoutTransferStatus.self,
            from: Data(contentsOf: url)
        )
    }

    @discardableResult
    public func ensurePending(
        workoutID: UUID,
        schemaVersion: Int,
        at date: Date = Date()
    ) throws -> BadmintonWorkoutTransferStatus {
        if let existing = try load(workoutID: workoutID) {
            guard existing.schemaVersion == schemaVersion else {
                throw BadmintonWorkoutTransferStateError.schemaMismatch(
                    expected: existing.schemaVersion,
                    actual: schemaVersion
                )
            }
            return existing
        }
        let status = BadmintonWorkoutTransferStatus(
            workoutID: workoutID,
            schemaVersion: schemaVersion,
            state: .pendingTransfer,
            updatedAt: date
        )
        try write(status)
        return status
    }

    @discardableResult
    public func markEnqueued(
        workoutID: UUID,
        schemaVersion: Int,
        at date: Date = Date()
    ) throws -> BadmintonWorkoutTransferStatus {
        try transition(
            workoutID: workoutID,
            schemaVersion: schemaVersion,
            to: .transferred,
            allowedFrom: [.pendingTransfer, .transferred],
            at: date
        )
    }

    @discardableResult
    public func markForRetry(
        workoutID: UUID,
        schemaVersion: Int,
        at date: Date = Date()
    ) throws -> BadmintonWorkoutTransferStatus {
        try transition(
            workoutID: workoutID,
            schemaVersion: schemaVersion,
            to: .pendingTransfer,
            allowedFrom: [.pendingTransfer, .transferred],
            at: date
        )
    }

    @discardableResult
    public func acknowledge(
        workoutID: UUID,
        schemaVersion: Int,
        at date: Date = Date()
    ) throws -> BadmintonWorkoutTransferStatus {
        try transition(
            workoutID: workoutID,
            schemaVersion: schemaVersion,
            to: .acknowledged,
            allowedFrom: [.pendingTransfer, .transferred, .acknowledged],
            at: date
        )
    }

    private func transition(
        workoutID: UUID,
        schemaVersion: Int,
        to target: BadmintonWorkoutSyncState,
        allowedFrom: Set<BadmintonWorkoutSyncState>,
        at date: Date
    ) throws -> BadmintonWorkoutTransferStatus {
        let current = try ensurePending(
            workoutID: workoutID,
            schemaVersion: schemaVersion,
            at: date
        )
        guard allowedFrom.contains(current.state) else {
            throw BadmintonWorkoutTransferStateError.invalidTransition(
                from: current.state,
                to: target
            )
        }
        var updated = current
        updated.state = target
        updated.updatedAt = date
        try write(updated)
        return updated
    }

    private func statusURL(for workoutID: UUID) -> URL {
        baseDirectory
            .appendingPathComponent(workoutID.uuidString.lowercased())
            .appendingPathExtension("json")
    }

    private func write(_ status: BadmintonWorkoutTransferStatus) throws {
        try fileManager.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
        try encoder.encode(status).write(
            to: statusURL(for: status.workoutID),
            options: .atomic
        )
    }
}
