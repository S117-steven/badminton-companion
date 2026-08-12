import Foundation

public struct ResearchCaptureTransferRequest: Equatable, Sendable {
    public let captureID: UUID
    public let schemaVersion: Int
    public let files: [ResearchCaptureStoredFile]

    public init(
        captureID: UUID,
        schemaVersion: Int,
        files: [ResearchCaptureStoredFile]
    ) {
        self.captureID = captureID
        self.schemaVersion = schemaVersion
        self.files = files
    }
}

public struct ResearchCaptureTransferAcknowledgement: Codable, Equatable, Sendable {
    public let captureID: UUID
    public let schemaVersion: Int

    public init(captureID: UUID, schemaVersion: Int) {
        self.captureID = captureID
        self.schemaVersion = schemaVersion
    }
}

public enum ResearchCaptureTransferOutboxError: Error, Equatable, Sendable {
    case acknowledgementSchemaMismatch(expected: Int, actual: Int)
    case captureNotTransferable(UUID, ResearchSyncState)
}

/// Produces file requests for a platform transport and advances sync state only
/// after the platform has queued both files or the phone has acknowledged a
/// complete idempotent import.
public actor ResearchCaptureTransferOutbox {
    private let store: ResearchCaptureFileStore

    public init(store: ResearchCaptureFileStore) {
        self.store = store
    }

    public func pendingRequests() async throws -> [ResearchCaptureTransferRequest] {
        let manifests = try await store.listManifests()
        var requests: [ResearchCaptureTransferRequest] = []
        for manifest in manifests where manifest.syncState != .acknowledged {
            requests.append(try await request(for: manifest))
        }
        return requests
    }

    public func request(captureID: UUID) async throws -> ResearchCaptureTransferRequest {
        let manifest = try await store.loadManifest(captureID: captureID)
        guard manifest.syncState != .acknowledged else {
            throw ResearchCaptureTransferOutboxError.captureNotTransferable(
                captureID,
                manifest.syncState
            )
        }
        return try await request(for: manifest)
    }

    @discardableResult
    public func markEnqueued(captureID: UUID) async throws -> ResearchCaptureManifest {
        try await store.updateSyncState(captureID: captureID, to: .transferred)
    }

    @discardableResult
    public func markForRetry(captureID: UUID) async throws -> ResearchCaptureManifest {
        try await store.updateSyncState(captureID: captureID, to: .pendingTransfer)
    }

    @discardableResult
    public func acknowledge(
        _ acknowledgement: ResearchCaptureTransferAcknowledgement
    ) async throws -> ResearchCaptureManifest {
        let manifest = try await store.loadManifest(captureID: acknowledgement.captureID)
        guard manifest.schemaVersion == acknowledgement.schemaVersion else {
            throw ResearchCaptureTransferOutboxError.acknowledgementSchemaMismatch(
                expected: manifest.schemaVersion,
                actual: acknowledgement.schemaVersion
            )
        }
        return try await store.updateSyncState(
            captureID: acknowledgement.captureID,
            to: .acknowledged
        )
    }

    private func request(
        for manifest: ResearchCaptureManifest
    ) async throws -> ResearchCaptureTransferRequest {
        let manifestFile = try await store.storedFile(
            captureID: manifest.id,
            kind: .manifest
        )
        let sampleFile = try await store.storedFile(
            captureID: manifest.id,
            kind: .samples
        )
        return ResearchCaptureTransferRequest(
            captureID: manifest.id,
            schemaVersion: manifest.schemaVersion,
            files: [manifestFile, sampleFile]
        )
    }
}
