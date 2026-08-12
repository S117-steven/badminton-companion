import BadmintonCore
import Foundation

@MainActor
final class ProductWorkoutViewModel: ObservableObject {
    @Published private(set) var snapshot = BadmintonWorkoutSessionSnapshot(
        phase: .idle,
        record: nil,
        activeDurationSeconds: 0,
        failure: nil
    )
    @Published private(set) var recoveredWorkout: BadmintonWorkoutRecord?
    @Published var errorMessage: String?

    private let store: BadmintonWorkoutFileStore
    private let coordinator: BadmintonWorkoutSessionCoordinator
    private var monitorTask: Task<Void, Never>?
    private var lastCheckpointAt: Date?

    init() {
        let store = BadmintonWorkoutFileStore(baseDirectory: Self.workoutDirectory)
        self.store = store
#if targetEnvironment(simulator)
        let platform: any WorkoutPlatformSession = SimulatorWorkoutPlatformSession()
#else
        let platform: any WorkoutPlatformSession = HealthKitWorkoutPlatformSession()
#endif
        coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)
    }

    func prepare() async {
        do {
            recoveredWorkout = try await store.recoverUnfinished().first
        } catch {
            errorMessage = "恢复未完成运动失败：\(error.localizedDescription)"
        }
    }

    func start() async {
        do {
            snapshot = try await coordinator.start()
            lastCheckpointAt = Date()
            errorMessage = nil
            startMonitoring()
        } catch let error as BadmintonWorkoutSessionError {
            switch error {
            case .authorizationNotGranted(.denied):
                errorMessage = "健康权限被拒绝，无法开始并写入羽毛球运动。请在系统设置中允许后重试。"
            case .authorizationNotGranted(.unavailable):
                errorMessage = "当前设备无法使用健康数据，运动尚未开始。"
            case .authorizationNotGranted:
                errorMessage = "健康授权没有完成，运动尚未开始。"
            default:
                errorMessage = "无法开始运动：\(error)"
            }
            snapshot = await coordinator.currentSnapshot()
        } catch {
            errorMessage = "无法开始运动：\(error.localizedDescription)"
            snapshot = await coordinator.currentSnapshot()
        }
    }

    func pauseOrResume() async {
        do {
            if snapshot.phase == .paused {
                snapshot = try await coordinator.resume()
            } else {
                snapshot = try await coordinator.pause()
            }
            errorMessage = nil
        } catch {
            errorMessage = "无法切换运动状态：\(error.localizedDescription)"
        }
    }

    func end() async {
        do {
            snapshot = try await coordinator.end()
            monitorTask?.cancel()
            monitorTask = nil
            errorMessage = nil
        } catch {
            snapshot = await coordinator.currentSnapshot()
            errorMessage = "运动已保留为中断记录，但健康运动保存失败：\(error.localizedDescription)"
        }
    }

    func reset() async {
        do {
            try await coordinator.reset()
            snapshot = await coordinator.currentSnapshot()
            errorMessage = nil
        } catch {
            errorMessage = "无法返回首页：\(error.localizedDescription)"
        }
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                if self.snapshot.phase == .running,
                   now.timeIntervalSince(self.lastCheckpointAt ?? .distantPast) >= 5 {
                    do {
                        self.snapshot = try await self.coordinator.checkpoint(at: now)
                        self.lastCheckpointAt = now
                    } catch {
                        self.errorMessage = "运动检查点保存失败：\(error.localizedDescription)"
                        self.snapshot = await self.coordinator.currentSnapshot(at: now)
                    }
                } else {
                    self.snapshot = await self.coordinator.currentSnapshot(at: now)
                }
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    private static var workoutDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("ProductData", isDirectory: true)
            .appendingPathComponent("Workouts", isDirectory: true)
    }
}
