@preconcurrency import WatchConnectivity
import BadmintonCore
import Foundation

extension Notification.Name {
    static let researchCaptureImported = Notification.Name(
        "badminton.research.capture-imported"
    )
}

final class PhoneResearchConnectivityController: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = PhoneResearchConnectivityController()

    private let inbox: ResearchCaptureTransferInbox
    private let stagingDirectory: URL
    private let fileManager = FileManager.default

    private override init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let researchRoot = documents.appendingPathComponent("ResearchData", isDirectory: true)
        let store = ResearchCaptureFileStore(
            baseDirectory: researchRoot.appendingPathComponent("Captures", isDirectory: true)
        )
        inbox = ResearchCaptureTransferInbox(
            inboxDirectory: researchRoot.appendingPathComponent("Inbox", isDirectory: true),
            destinationStore: store
        )
        stagingDirectory = researchRoot.appendingPathComponent(
            "ConnectivityStaging",
            isDirectory: true
        )
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
        guard let dictionary = file.metadata else { return }
        let metadata: ResearchCaptureTransferMetadata
        do {
            metadata = try ResearchTransferPropertyListCodec.decodeMetadata(dictionary)
        } catch {
            return
        }

        let stagedURL: URL
        do {
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            stagedURL = stagingDirectory.appendingPathComponent(
                "\(metadata.captureID.uuidString.lowercased())-\(metadata.kind.rawValue)-\(UUID().uuidString)"
            )
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
                switch result {
                case .awaitingRemainingFile:
                    break
                case .imported(let captureID), .duplicate(let captureID):
                    session.transferUserInfo(
                        ResearchTransferPropertyListCodec.encode(
                            acknowledgement: .init(
                                captureID: captureID,
                                schemaVersion: metadata.schemaVersion
                            )
                        )
                    )
                    NotificationCenter.default.post(
                        name: .researchCaptureImported,
                        object: captureID
                    )
                }
            } catch {
                // The staged file remains retriable from the watch because no
                // acknowledgement is sent on any validation or import failure.
            }
        }
    }
}
