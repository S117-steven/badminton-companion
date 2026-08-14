import Foundation

public struct BadmintonWorkoutTransferRequest: Equatable, Sendable {
    public let workoutID: UUID
    public let schemaVersion: Int
    public let file: BadmintonWorkoutStoredFile

    public init(
        workoutID: UUID,
        schemaVersion: Int,
        file: BadmintonWorkoutStoredFile
    ) {
        self.workoutID = workoutID
        self.schemaVersion = schemaVersion
        self.file = file
    }
}

public struct BadmintonWorkoutTransferMetadata: Codable, Equatable, Sendable {
    public let workoutID: UUID
    public let schemaVersion: Int
    public let byteCount: Int64

    public init(workoutID: UUID, schemaVersion: Int, byteCount: Int64) {
        self.workoutID = workoutID
        self.schemaVersion = schemaVersion
        self.byteCount = byteCount
    }
}

public struct BadmintonWorkoutTransferAcknowledgement: Codable, Equatable, Sendable {
    public let workoutID: UUID
    public let schemaVersion: Int

    public init(workoutID: UUID, schemaVersion: Int) {
        self.workoutID = workoutID
        self.schemaVersion = schemaVersion
    }
}

public enum BadmintonWorkoutTransferOutboxError: Error, Equatable, Sendable {
    case workoutNotTerminal(UUID, WorkoutLifecycleState)
    case workoutAlreadyAcknowledged(UUID)
    case acknowledgementSchemaMismatch(expected: Int, actual: Int)
}

/// Selects terminal watch workouts for background delivery. Active records are
/// never exported, so the phone cannot receive a half-finished workout fact.
public actor BadmintonWorkoutTransferOutbox {
    private let workoutStore: BadmintonWorkoutFileStore
    private let stateStore: BadmintonWorkoutTransferStateStore

    public init(
        workoutStore: BadmintonWorkoutFileStore,
        stateStore: BadmintonWorkoutTransferStateStore
    ) {
        self.workoutStore = workoutStore
        self.stateStore = stateStore
    }

    public func pendingRequests() async throws -> [BadmintonWorkoutTransferRequest] {
        let records = try await workoutStore.list()
        var requests: [BadmintonWorkoutTransferRequest] = []
        for record in records where Self.isTerminal(record) {
            let status = try await stateStore.ensurePending(
                workoutID: record.id,
                schemaVersion: record.schemaVersion,
                at: record.updatedAt
            )
            guard status.state != .acknowledged else { continue }
            requests.append(try await request(for: record, status: status))
        }
        return requests
    }

    public func request(workoutID: UUID) async throws -> BadmintonWorkoutTransferRequest {
        let record = try await workoutStore.load(id: workoutID)
        guard Self.isTerminal(record) else {
            throw BadmintonWorkoutTransferOutboxError.workoutNotTerminal(
                workoutID,
                record.lifecycleState
            )
        }
        let status = try await stateStore.ensurePending(
            workoutID: workoutID,
            schemaVersion: record.schemaVersion,
            at: record.updatedAt
        )
        guard status.state != .acknowledged else {
            throw BadmintonWorkoutTransferOutboxError.workoutAlreadyAcknowledged(
                workoutID
            )
        }
        return try await request(for: record, status: status)
    }

    @discardableResult
    public func markEnqueued(
        workoutID: UUID,
        schemaVersion: Int
    ) async throws -> BadmintonWorkoutTransferStatus {
        try await stateStore.markEnqueued(
            workoutID: workoutID,
            schemaVersion: schemaVersion
        )
    }

    @discardableResult
    public func markForRetry(
        workoutID: UUID,
        schemaVersion: Int
    ) async throws -> BadmintonWorkoutTransferStatus {
        try await stateStore.markForRetry(
            workoutID: workoutID,
            schemaVersion: schemaVersion
        )
    }

    @discardableResult
    public func acknowledge(
        _ acknowledgement: BadmintonWorkoutTransferAcknowledgement
    ) async throws -> BadmintonWorkoutTransferStatus {
        let record = try await workoutStore.load(id: acknowledgement.workoutID)
        guard record.schemaVersion == acknowledgement.schemaVersion else {
            throw BadmintonWorkoutTransferOutboxError
                .acknowledgementSchemaMismatch(
                    expected: record.schemaVersion,
                    actual: acknowledgement.schemaVersion
                )
        }
        return try await stateStore.acknowledge(
            workoutID: acknowledgement.workoutID,
            schemaVersion: acknowledgement.schemaVersion
        )
    }

    private func request(
        for record: BadmintonWorkoutRecord,
        status: BadmintonWorkoutTransferStatus
    ) async throws -> BadmintonWorkoutTransferRequest {
        guard status.schemaVersion == record.schemaVersion else {
            throw BadmintonWorkoutTransferStateError.schemaMismatch(
                expected: status.schemaVersion,
                actual: record.schemaVersion
            )
        }
        return .init(
            workoutID: record.id,
            schemaVersion: record.schemaVersion,
            file: try await workoutStore.storedFile(id: record.id)
        )
    }

    private static func isTerminal(_ record: BadmintonWorkoutRecord) -> Bool {
        record.lifecycleState == .completed || record.lifecycleState == .interrupted
    }
}

public enum BadmintonWorkoutInboxResult: Equatable, Sendable {
    case imported(UUID)
    case duplicate(UUID)
}

public enum BadmintonWorkoutInboxError: Error, Equatable, Sendable {
    case byteCountMismatch(expected: Int64, actual: Int64)
    case unsupportedSchemaVersion(Int)
    case recordIdentityMismatch
    case workoutNotTerminal(WorkoutLifecycleState)
}

/// Validates one atomic workout record before importing it into the phone's
/// long-term store. Future hit details must join a versioned atomic envelope;
/// they must never be transferred as an unverified partial side channel.
public actor BadmintonWorkoutTransferInbox {
    private let stagingDirectory: URL
    private let destinationStore: BadmintonWorkoutFileStore
    private let fileManager: FileManager
    private let decoder: JSONDecoder

    public init(
        stagingDirectory: URL,
        destinationStore: BadmintonWorkoutFileStore,
        fileManager: FileManager = .default
    ) {
        self.stagingDirectory = stagingDirectory
        self.destinationStore = destinationStore
        self.fileManager = fileManager
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func receive(
        fileAt sourceURL: URL,
        metadata: BadmintonWorkoutTransferMetadata
    ) async throws -> BadmintonWorkoutInboxResult {
        guard metadata.schemaVersion <= BadmintonWorkoutRecord.currentSchemaVersion else {
            throw BadmintonWorkoutInboxError.unsupportedSchemaVersion(
                metadata.schemaVersion
            )
        }
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let actualByteCount = Int64(values.fileSize ?? 0)
        guard actualByteCount == metadata.byteCount else {
            throw BadmintonWorkoutInboxError.byteCountMismatch(
                expected: metadata.byteCount,
                actual: actualByteCount
            )
        }

        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        let stagedURL = stagingDirectory
            .appendingPathComponent(metadata.workoutID.uuidString.lowercased())
            .appendingPathExtension("incoming")
        let temporaryURL = stagingDirectory
            .appendingPathComponent(UUID().uuidString.lowercased())
            .appendingPathExtension("copying")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
            try? fileManager.removeItem(at: stagedURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: stagedURL.path) {
            try fileManager.removeItem(at: stagedURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: stagedURL)

        let record = try decoder.decode(
            BadmintonWorkoutRecord.self,
            from: Data(contentsOf: stagedURL)
        )
        guard record.id == metadata.workoutID,
              record.schemaVersion == metadata.schemaVersion else {
            throw BadmintonWorkoutInboxError.recordIdentityMismatch
        }
        guard record.lifecycleState == .completed
                || record.lifecycleState == .interrupted else {
            throw BadmintonWorkoutInboxError.workoutNotTerminal(
                record.lifecycleState
            )
        }
        let result = try await destinationStore.importRecord(record)
        switch result {
        case .imported(let workoutID): return .imported(workoutID)
        case .duplicate(let workoutID): return .duplicate(workoutID)
        }
    }
}
