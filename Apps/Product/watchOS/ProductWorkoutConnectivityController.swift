@preconcurrency import WatchConnectivity
import BadmintonCore
import Foundation

extension Notification.Name {
    static let productWorkoutSyncChanged = Notification.Name(
        "badminton.product.workout-sync-changed"
    )
}

/// Queues finished workouts for background delivery. It never requires the
/// phone to be reachable while a workout is running.
final class ProductWorkoutConnectivityController: NSObject, WCSessionDelegate,
    @unchecked Sendable {
    static let shared = ProductWorkoutConnectivityController()

    private let outbox: BadmintonWorkoutTransferOutbox
    private let snapshotStore: BadmintonWorkoutTransferSnapshotStore

    private override init() {
        let runtime = ProductWorkoutRuntime.shared
        outbox = runtime.transferOutbox
        snapshotStore = runtime.transferSnapshotStore
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func queuePendingWorkouts() {
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
                // Records remain local and are rediscovered on next activation.
            }
        }
    }

    func queueWorkout(_ workoutID: UUID) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else {
            activate()
            return
        }
        Task { [outbox, snapshotStore] in
            do {
                let request = try await outbox.request(workoutID: workoutID)
                try await Self.enqueue(
                    request,
                    using: WCSession.default,
                    outbox: outbox,
                    snapshotStore: snapshotStore
                )
            } catch {
                // A terminal record remains available for later retry.
            }
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        queuePendingWorkouts()
    }

    func session(
        _ session: WCSession,
        didReceiveUserInfo userInfo: [String: Any] = [:]
    ) {
        guard let acknowledgement = try? BadmintonWorkoutTransferPropertyListCodec
            .decodeAcknowledgement(userInfo) else {
            return
        }
        Task { [outbox] in
            do {
                _ = try await outbox.acknowledge(acknowledgement)
                NotificationCenter.default.post(
                    name: .productWorkoutSyncChanged,
                    object: acknowledgement.workoutID
                )
            } catch {
                // A mismatched acknowledgement never advances local state.
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
              let metadata = try? BadmintonWorkoutTransferPropertyListCodec
                .decodeMetadata(dictionary) else {
            return
        }
        Task { [outbox] in
            _ = try? await outbox.markForRetry(
                workoutID: metadata.workoutID,
                schemaVersion: metadata.schemaVersion
            )
            NotificationCenter.default.post(
                name: .productWorkoutSyncChanged,
                object: metadata.workoutID
            )
        }
    }

    private static func enqueue(
        _ request: BadmintonWorkoutTransferRequest,
        using session: WCSession,
        outbox: BadmintonWorkoutTransferOutbox,
        snapshotStore: BadmintonWorkoutTransferSnapshotStore
    ) async throws {
        let snapshot = try await snapshotStore.createSnapshot(for: request)
        session.transferFile(
            snapshot.file.url,
            metadata: BadmintonWorkoutTransferPropertyListCodec.encode(
                metadata: .init(
                    workoutID: snapshot.workoutID,
                    schemaVersion: snapshot.schemaVersion,
                    byteCount: snapshot.file.byteCount
                )
            )
        )
        _ = try await outbox.markEnqueued(
            workoutID: snapshot.workoutID,
            schemaVersion: snapshot.schemaVersion
        )
        NotificationCenter.default.post(
            name: .productWorkoutSyncChanged,
            object: snapshot.workoutID
        )
    }
}
