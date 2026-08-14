@preconcurrency import WatchConnectivity
import BadmintonCore
import Foundation

extension Notification.Name {
    static let productWorkoutImported = Notification.Name(
        "badminton.product.workout-imported"
    )
}

private final class ProductWorkoutMessageReplyHandler: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ message: [String: Any]) {
        handler(message)
    }
}

final class ProductPhoneConnectivityController: NSObject, WCSessionDelegate,
    @unchecked Sendable {
    static let shared = ProductPhoneConnectivityController()

    private let inbox: BadmintonWorkoutTransferInbox
    private let stagingDirectory: URL
    private let fileManager = FileManager.default

    private override init() {
        inbox = ProductPhoneRuntime.shared.workoutInbox
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        stagingDirectory = documents
            .appendingPathComponent("ProductData", isDirectory: true)
            .appendingPathComponent("ConnectivityStaging", isDirectory: true)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let dictionary = file.metadata,
              let metadata = try? BadmintonWorkoutTransferPropertyListCodec
                .decodeMetadata(dictionary) else {
            return
        }

        let stagedURL: URL
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            stagedURL = stagingDirectory
                .appendingPathComponent(metadata.workoutID.uuidString.lowercased())
                .appendingPathExtension(UUID().uuidString.lowercased())
            try fileManager.copyItem(at: file.fileURL, to: stagedURL)
        } catch {
            return
        }

        Task { [inbox, fileManager] in
            defer { try? fileManager.removeItem(at: stagedURL) }
            do {
                let result = try await inbox.receive(
                    fileAt: stagedURL,
                    metadata: metadata
                )
                let workoutID: UUID
                switch result {
                case .imported(let id), .duplicate(let id): workoutID = id
                }
                session.transferUserInfo(
                    BadmintonWorkoutTransferPropertyListCodec.encode(
                        acknowledgement: .init(
                            workoutID: workoutID,
                            schemaVersion: metadata.schemaVersion
                        )
                    )
                )
                NotificationCenter.default.post(
                    name: .productWorkoutImported,
                    object: workoutID
                )
            } catch {
                // No acknowledgement is sent. The watch retains and retries.
            }
        }
    }

    func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let immediate = try? BadmintonWorkoutTransferPropertyListCodec
            .decodeImmediateWorkout(message) else {
            return
        }

        let stagedURL: URL
        let reply = ProductWorkoutMessageReplyHandler(replyHandler)
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            stagedURL = stagingDirectory
                .appendingPathComponent(
                    immediate.metadata.workoutID.uuidString.lowercased()
                )
                .appendingPathExtension(UUID().uuidString.lowercased())
            try immediate.payload.write(to: stagedURL, options: .atomic)
        } catch {
            return
        }

        Task { [inbox, fileManager] in
            defer { try? fileManager.removeItem(at: stagedURL) }
            do {
                let result = try await inbox.receive(
                    fileAt: stagedURL,
                    metadata: immediate.metadata
                )
                let workoutID: UUID
                switch result {
                case .imported(let id), .duplicate(let id): workoutID = id
                }
                reply(
                    BadmintonWorkoutTransferPropertyListCodec.encode(
                        acknowledgement: .init(
                            workoutID: workoutID,
                            schemaVersion: immediate.metadata.schemaVersion
                        )
                    )
                )
                NotificationCenter.default.post(
                    name: .productWorkoutImported,
                    object: workoutID
                )
            } catch {
                // The background file remains the reliable fallback.
            }
        }
    }
}
