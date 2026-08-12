@preconcurrency import WatchConnectivity
import BadmintonCore
import Foundation

extension Notification.Name {
    static let researchCaptureSyncChanged = Notification.Name(
        "badminton.research.capture-sync-changed"
    )
    static let researchActiveParticipantChanged = Notification.Name(
        "badminton.research.active-participant-changed"
    )
}

final class WatchResearchConnectivityController: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchResearchConnectivityController()

    private let outbox: ResearchCaptureTransferOutbox
    private let snapshotStore: ResearchCaptureTransferSnapshotStore

    private override init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let store = ResearchCaptureFileStore(
            baseDirectory: documents
                .appendingPathComponent("ResearchData", isDirectory: true)
                .appendingPathComponent("Captures", isDirectory: true)
        )
        outbox = ResearchCaptureTransferOutbox(store: store)
        snapshotStore = ResearchCaptureTransferSnapshotStore(
            baseDirectory: documents
                .appendingPathComponent("ResearchData", isDirectory: true)
                .appendingPathComponent("ConnectivityOutgoing", isDirectory: true)
        )
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    var activeParticipantID: UUID? {
        UserDefaults.standard.string(
            forKey: Self.activeParticipantKey
        ).flatMap(UUID.init(uuidString:))
    }

    func queuePendingCaptures() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            activate()
            return
        }
        Task { [outbox, snapshotStore] in
            do {
                for request in try await outbox.pendingRequests() {
                    try await Self.enqueue(
                        request,
                        using: WCSession.default,
                        outbox: outbox,
                        snapshotStore: snapshotStore
                    )
                }
            } catch {
                // Capture remains pending and will be retried on next activation.
            }
        }
    }

    func queueCapture(_ captureID: UUID) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            activate()
            return
        }
        Task { [outbox, snapshotStore] in
            do {
                let request = try await outbox.request(captureID: captureID)
                try await Self.enqueue(
                    request,
                    using: WCSession.default,
                    outbox: outbox,
                    snapshotStore: snapshotStore
                )
            } catch {
                // Capture remains locally available for a later retry.
            }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        receiveActiveParticipant(from: session.receivedApplicationContext)
        queuePendingCaptures()
    }

    func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        receiveActiveParticipant(from: applicationContext)
    }

    func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        let acknowledgement: ResearchCaptureTransferAcknowledgement
        do {
            acknowledgement = try ResearchTransferPropertyListCodec
                .decodeAcknowledgement(userInfo)
        } catch {
            return
        }
        Task { [outbox] in
            do {
                _ = try await outbox.acknowledge(acknowledgement)
                NotificationCenter.default.post(
                    name: .researchCaptureSyncChanged,
                    object: acknowledgement.captureID
                )
            } catch {
                // A mismatched acknowledgement never advances local sync state.
            }
        }
    }

    func session(
        _ session: WCSession,
        fileTransfer: WCSessionFileTransfer,
        didFinish error: Error?
    ) {
        let snapshotURL = fileTransfer.file.fileURL
        Task { [snapshotStore] in
            await snapshotStore.removeSnapshotFile(at: snapshotURL)
        }
        guard error != nil,
              let dictionary = fileTransfer.file.metadata,
              let metadata = try? ResearchTransferPropertyListCodec.decodeMetadata(dictionary)
        else { return }
        Task { [outbox] in
            _ = try? await outbox.markForRetry(captureID: metadata.captureID)
            NotificationCenter.default.post(
                name: .researchCaptureSyncChanged,
                object: metadata.captureID
            )
        }
    }

    private static func enqueue(
        _ request: ResearchCaptureTransferRequest,
        using session: WCSession,
        outbox: ResearchCaptureTransferOutbox,
        snapshotStore: ResearchCaptureTransferSnapshotStore
    ) async throws {
        let snapshot = try await snapshotStore.createSnapshot(for: request)
        for file in snapshot.files {
            session.transferFile(
                file.url,
                metadata: ResearchTransferPropertyListCodec.encode(
                    metadata: .init(
                        captureID: snapshot.captureID,
                        schemaVersion: snapshot.schemaVersion,
                        kind: file.kind,
                        byteCount: file.byteCount
                    )
                )
            )
        }
        _ = try await outbox.markEnqueued(captureID: snapshot.captureID)
        NotificationCenter.default.post(
            name: .researchCaptureSyncChanged,
            object: snapshot.captureID
        )
    }

    private func receiveActiveParticipant(from dictionary: [String: Any]) {
        guard let selection = try? ResearchTransferPropertyListCodec
            .decodeActiveParticipant(dictionary) else {
            return
        }
        UserDefaults.standard.set(
            selection.participantID.uuidString,
            forKey: Self.activeParticipantKey
        )
        NotificationCenter.default.post(
            name: .researchActiveParticipantChanged,
            object: selection.participantID
        )
    }

    private static let activeParticipantKey = "research.active-participant-id"
}
