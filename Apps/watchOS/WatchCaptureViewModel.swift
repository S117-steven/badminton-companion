import BadmintonCore
import Foundation
import WatchKit

@MainActor
final class WatchCaptureViewModel: ObservableObject {
    @Published private(set) var snapshot = ResearchCaptureSessionSnapshot(
        phase: .idle,
        captureID: nil,
        startedAt: nil,
        receivedSampleCount: 0,
        persistedSampleCount: 0,
        failure: nil
    )
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var reviewStatus = ResearchReviewStatus.pending
    @Published var errorMessage: String?

    let mode: ResearchCaptureMode
    let manualLabel: ManualActionLabel?

    private let store: ResearchCaptureFileStore
    private var coordinator: ResearchCaptureSessionCoordinator?
    private var monitorTask: Task<Void, Never>?

    init(mode: ResearchCaptureMode, manualLabel: ManualActionLabel?) {
        self.mode = mode
        self.manualLabel = manualLabel
        store = ResearchCaptureFileStore(baseDirectory: Self.captureDirectory)
    }

    func start() async {
#if targetEnvironment(simulator)
        do {
            let source = SimulatorResearchMotionSource()
            let coordinator = try ResearchCaptureSessionCoordinator(
                store: store,
                flushBatchSize: 75
            )
            self.coordinator = coordinator
            let manifest = ResearchCaptureManifest(
                participantID: Self.localParticipantID,
                mode: mode,
                manualLabel: manualLabel,
                provenance: source.provenance,
                device: Self.deviceMetadata
            )
            snapshot = try await coordinator.start(
                manifest: manifest,
                source: source,
                configuration: .init(requestedIntervalSeconds: 0.02)
            )
            errorMessage = nil
            startMonitoring()
        } catch {
            errorMessage = String(describing: error)
        }
#else
        errorMessage = "真机 Core Motion 适配器将在阶段 2 接入；当前不以合成数据代替真机采集。"
#endif
    }

    func stop() async {
        guard let coordinator else { return }
        do {
            snapshot = try await coordinator.stop()
            monitorTask?.cancel()
            monitorTask = nil
            updateElapsed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func interruptIfNeeded() async {
        guard snapshot.phase == .collecting, let coordinator else { return }
        do {
            snapshot = try await coordinator.interrupt()
        } catch {
            errorMessage = String(describing: error)
        }
        monitorTask?.cancel()
        monitorTask = nil
    }

    func mark(_ status: ResearchReviewStatus) async {
        guard let captureID = snapshot.captureID else { return }
        do {
            _ = try await store.updateReview(
                captureID: captureID,
                status: status,
                invalidReason: status == .invalid ? "手表研发采集者标记" : nil
            )
            reviewStatus = status
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let coordinator = self.coordinator else { return }
                self.snapshot = await coordinator.currentSnapshot()
                self.updateElapsed()
                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    return
                }
            }
        }
    }

    private func updateElapsed() {
        guard let startedAt = snapshot.startedAt else {
            elapsedSeconds = 0
            return
        }
        elapsedSeconds = max(0, Date().timeIntervalSince(startedAt))
    }

    private static var captureDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("ResearchData", isDirectory: true)
            .appendingPathComponent("Captures", isDirectory: true)
    }

    private static var localParticipantID: UUID {
        let key = "research.local-participant-id"
        if let value = UserDefaults.standard.string(forKey: key),
           let id = UUID(uuidString: value) {
            return id
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    private static var deviceMetadata: ResearchDeviceMetadata {
        .init(
            hardwareModel: WKInterfaceDevice.current().model,
            operatingSystemVersion: WKInterfaceDevice.current().systemVersion,
            applicationVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            applicationBuild: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown"
        )
    }
}
