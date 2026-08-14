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

    private let runtime: ProductWorkoutRuntime
    private let store: BadmintonWorkoutFileStore
    private let coordinator: BadmintonWorkoutSessionCoordinator
    private var monitorTask: Task<Void, Never>?
    private var lastCheckpointAt: Date?

    init(runtime: ProductWorkoutRuntime = .shared) {
        self.runtime = runtime
        store = runtime.store
        coordinator = runtime.coordinator
    }

    func prepare() async {
        do {
            if let recoveryTask = runtime.activeRecoveryTask(),
               let recoveredSnapshot = try await recoveryTask.value {
                snapshot = recoveredSnapshot
                recoveredWorkout = nil
                errorMessage = nil
                startMonitoring()
                ProductWorkoutConnectivityController.shared.queuePendingWorkouts()
                return
            }
            recoveredWorkout = try await store.recoverUnfinished().first
            snapshot = await coordinator.currentSnapshot()
            ProductWorkoutConnectivityController.shared.queuePendingWorkouts()
        } catch {
            recoveredWorkout = try? await store.recoverUnfinished().first
            snapshot = await coordinator.currentSnapshot()
            errorMessage = "恢复 HealthKit 运动失败，已保护本地检查点：\(error.localizedDescription)"
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
            queueCurrentTerminalWorkout()
        } catch {
            snapshot = await coordinator.currentSnapshot()
            errorMessage = "运动已保留为中断记录，但健康运动保存失败：\(error.localizedDescription)"
            queueCurrentTerminalWorkout()
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

    private func queueCurrentTerminalWorkout() {
        guard let record = snapshot.record,
              record.lifecycleState == .completed
                || record.lifecycleState == .interrupted else {
            return
        }
        ProductWorkoutConnectivityController.shared.queueWorkout(record.id)
    }
}
