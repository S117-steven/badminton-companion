import BadmintonCore
import Foundation

struct PreparedResearchExport: Equatable {
    let captureID: UUID
    let fileURL: URL
    let sampleCount: Int
    let includesParticipant: Bool
}

struct PreparedResearchBatchExport: Equatable {
    let directoryURL: URL
    let fileURLs: [URL]
    let captureCount: Int
    let totalSampleCount: Int
}

@MainActor
final class PhoneResearchViewModel: ObservableObject {
    @Published private(set) var participants: [ResearchParticipant] = []
    @Published private(set) var activeParticipantID: UUID?
    @Published private(set) var captures: [ResearchCaptureManifest] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var simulatorImportMessage: String?
    @Published private(set) var preparedExport: PreparedResearchExport?
    @Published private(set) var preparedBatchExport: PreparedResearchBatchExport?
    @Published private(set) var isPreparingExport = false
    @Published private(set) var exportMessage: String?

    private let participantStore: ResearchParticipantFileStore
    private let captureStore: ResearchCaptureFileStore
    private let transferInbox: ResearchCaptureTransferInbox
    private let exporter: ResearchCaptureNDJSONExporter
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
        exporter = ResearchCaptureNDJSONExporter(
            captureStore: captureStore,
            participantStore: participantStore
        )
        simulatorOutgoingDirectory = researchRoot.appendingPathComponent(
            "SimulatorOutgoing",
            isDirectory: true
        )
        activeParticipantID = UserDefaults.standard.string(
            forKey: Self.activeParticipantKey
        ).flatMap(UUID.init(uuidString:))
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            participants = try await participantStore.list()
            captures = try await captureStore.listManifests()
            if activeParticipantID == nil, let firstParticipant = participants.first {
                setActiveParticipant(firstParticipant.id)
            } else if let activeParticipantID {
                PhoneResearchConnectivityController.shared.publishActiveParticipant(
                    activeParticipantID
                )
            }
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
            setActiveParticipant(participant.id)
            await reload()
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func setActiveParticipant(_ participantID: UUID) {
        activeParticipantID = participantID
        UserDefaults.standard.set(
            participantID.uuidString,
            forKey: Self.activeParticipantKey
        )
        PhoneResearchConnectivityController.shared.publishActiveParticipant(
            participantID
        )
    }

    func saveResearchMetadata(
        captureID: UUID,
        reviewStatus: ResearchReviewStatus,
        invalidReason: String,
        notes: String,
        speedText: String,
        speedUnit: ResearchSpeedUnit,
        speedSource: String,
        measurementStatus: ExternalMeasurementStatus,
        pairingIdentifier: String
    ) async -> Bool {
        do {
            let speedReference: ExternalSpeedReference?
            let trimmedSpeed = speedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSource = speedSource.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedPairingID = pairingIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSpeed.isEmpty, trimmedSource.isEmpty, trimmedPairingID.isEmpty {
                speedReference = nil
            } else {
                guard let measuredValue = Double(trimmedSpeed) else {
                    errorMessage = "外部真实速度必须是有效数字。"
                    return false
                }
                speedReference = .init(
                    measuredValue: measuredValue,
                    unit: speedUnit,
                    sourceDescription: trimmedSource,
                    status: measurementStatus,
                    pairingIdentifier: trimmedPairingID
                )
            }
            _ = try await captureStore.updateResearchMetadata(
                captureID: captureID,
                reviewStatus: reviewStatus,
                invalidReason: invalidReason,
                notes: notes,
                externalSpeedReference: speedReference
            )
            await reload()
            return true
        } catch {
            errorMessage = researchMetadataErrorMessage(error)
            return false
        }
    }

    func loadChartSamples(captureID: UUID) async throws -> [ResearchMotionSample] {
        try await captureStore.loadSamples(
            captureID: captureID,
            maximumCount: 4_500
        )
    }

    func prepareExport(captureID: UUID) async {
        isPreparingExport = true
        exportMessage = nil
        defer { isPreparingExport = false }

        do {
            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BadmintonResearchExports", isDirectory: true)
            let destination = exportDirectory
                .appendingPathComponent(captureID.uuidString.lowercased())
                .appendingPathExtension("badminton-ndjson")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            let result = try await exporter.export(
                captureID: captureID,
                to: destination
            )
            preparedExport = PreparedResearchExport(
                captureID: captureID,
                fileURL: result.fileURL,
                sampleCount: result.sampleCount,
                includesParticipant: result.includesParticipant
            )
            exportMessage = result.includesParticipant
                ? "已生成含测试者资料的完整 NDJSON。"
                : "已生成 NDJSON，但该采集尚未匹配手机端测试者资料。"
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func prepareBatchExport(captureIDs: [UUID]) async {
        isPreparingExport = true
        exportMessage = nil
        defer { isPreparingExport = false }

        do {
            let exportRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("BadmintonResearchBatchExports", isDirectory: true)
            let destination = exportRoot.appendingPathComponent(
                "batch-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            let result = try await exporter.exportBatch(
                captureIDs: captureIDs,
                to: destination
            )
            preparedBatchExport = .init(
                directoryURL: result.directoryURL,
                fileURLs: result.files.map(\.fileURL),
                captureCount: result.files.count,
                totalSampleCount: result.totalSampleCount
            )
            exportMessage = "已准备 \(result.files.count) 个采集、\(result.totalSampleCount) 条原始记录。"
            errorMessage = nil
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

    private func researchMetadataErrorMessage(_ error: Error) -> String {
        guard let validationError = error as? ResearchCaptureValidationError else {
            return String(describing: error)
        }
        return switch validationError {
        case .invalidExternalSpeedValue:
            "外部真实速度必须大于 0。"
        case .missingExternalSpeedSource:
            "请填写测速设备或方法。"
        case .missingExternalSpeedPairingIdentifier:
            "请填写能与原始数据一一对应的配对标识。"
        case .externalSpeedRequiresSingleSmash:
            "当前只允许为“单次动作 + 杀球”录入一对一真实测速。"
        case .externalSpeedRequiresPhysicalSensor:
            "外部真实测速只能与真实 Apple Watch 传感器采集配对。"
        default:
            String(describing: error)
        }
    }

    private static let activeParticipantKey = "research.active-participant-id"
}
