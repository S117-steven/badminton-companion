import BadmintonCore
import Foundation

@MainActor
final class PhoneResearchViewModel: ObservableObject {
    @Published private(set) var participants: [ResearchParticipant] = []
    @Published private(set) var captures: [ResearchCaptureManifest] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var simulatorImportMessage: String?

    private let participantStore: ResearchParticipantFileStore
    private let captureStore: ResearchCaptureFileStore
    private let transferInbox: ResearchCaptureTransferInbox
    private let simulatorOutgoingDirectory: URL

    init() {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let researchRoot = documents.appendingPathComponent("ResearchData", isDirectory: true)
        let captureStore = ResearchCaptureFileStore(
            baseDirectory: researchRoot.appendingPathComponent("Captures", isDirectory: true)
        )
        self.captureStore = captureStore
        participantStore = ResearchParticipantFileStore(
            baseDirectory: researchRoot.appendingPathComponent("Participants", isDirectory: true)
        )
        transferInbox = ResearchCaptureTransferInbox(
            inboxDirectory: researchRoot.appendingPathComponent("Inbox", isDirectory: true),
            destinationStore: captureStore
        )
        simulatorOutgoingDirectory = researchRoot.appendingPathComponent(
            "SimulatorOutgoing",
            isDirectory: true
        )
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            participants = try await participantStore.list()
            captures = try await captureStore.listManifests()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func saveParticipant(
        heightText: String,
        armSpanText: String,
        skillLevelCode: String
    ) async -> Bool {
        guard let height = Double(heightText), let armSpan = Double(armSpanText) else {
            errorMessage = "身高和臂展必须是有效数字。"
            return false
        }

        do {
            let participant = ResearchParticipant(
                heightCentimeters: height,
                armSpanCentimeters: armSpan,
                skillLevelCode: skillLevelCode,
                skillLevelDefinitionVersion: 1
            )
            try await participantStore.save(participant)
            await reload()
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func updateReview(
        captureID: UUID,
        status: ResearchReviewStatus
    ) async {
        do {
            _ = try await captureStore.updateReview(
                captureID: captureID,
                status: status,
                invalidReason: status == .invalid ? "Simulator 研发复核标记" : nil
            )
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }

#if targetEnvironment(simulator)
    func runSimulatorInboundCheck() async {
        do {
            let outgoingStore = ResearchCaptureFileStore(
                baseDirectory: simulatorOutgoingDirectory
            )
            let manifest = ResearchCaptureManifest(
                participantID: participants.first?.id ?? UUID(),
                mode: .singleAction,
                manualLabel: .normalShot,
                provenance: .simulatorSynthetic,
                device: .init(
                    hardwareModel: "iPhone Simulator transfer fixture",
                    operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    applicationVersion: appVersion,
                    applicationBuild: appBuild
                )
            )
            try await outgoingStore.createCapture(manifest)
            var samples: [ResearchMotionSample] = []
            samples.reserveCapacity(30)
            for index in 0..<30 {
                let timestamp = Double(index) * 0.01
                let angle = Double(index) * 0.1
                let acceleration = SensorVector3(
                    x: sin(angle),
                    y: cos(angle),
                    z: 9.80665
                )
                samples.append(ResearchMotionSample(
                    sequenceNumber: UInt64(index),
                    source: .accelerometer,
                    monotonicTimestampSeconds: timestamp,
                    elapsedTimeSeconds: timestamp,
                    actualIntervalSeconds: index == 0 ? nil : 0.01,
                    accelerationMetersPerSecondSquared: acceleration
                ))
            }
            _ = try await outgoingStore.append(samples, to: manifest.id)
            let completed = try await outgoingStore.finishCapture(
                captureID: manifest.id,
                endedAt: manifest.startedAt.addingTimeInterval(0.3),
                quality: .init(
                    requestedIntervalSeconds: 0.01,
                    averageActualIntervalSeconds: 0.01,
                    maximumActualIntervalSeconds: 0.01
                )
            )

            let manifestFile = try await outgoingStore.storedFile(
                captureID: manifest.id,
                kind: .manifest
            )
            let sampleFile = try await outgoingStore.storedFile(
                captureID: manifest.id,
                kind: .samples
            )
            _ = try await transferInbox.receive(
                fileAt: manifestFile.url,
                metadata: transferMetadata(
                    for: manifestFile,
                    schemaVersion: completed.schemaVersion
                )
            )
            let result = try await transferInbox.receive(
                fileAt: sampleFile.url,
                metadata: transferMetadata(
                    for: sampleFile,
                    schemaVersion: completed.schemaVersion
                )
            )
            simulatorImportMessage = result == .imported(manifest.id)
                ? "Simulator 合成采集已通过双文件入站校验。"
                : "该 Simulator 合成采集已存在，未重复创建。"
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }
#endif

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
    }

    private func transferMetadata(
        for file: ResearchCaptureStoredFile,
        schemaVersion: Int
    ) -> ResearchCaptureTransferMetadata {
        .init(
            captureID: file.captureID,
            schemaVersion: schemaVersion,
            kind: file.kind,
            byteCount: file.byteCount
        )
    }
}
