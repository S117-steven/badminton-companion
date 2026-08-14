import BadmintonCore
import Foundation

extension Notification.Name {
    static let productActiveWorkoutRecoveryRequested = Notification.Name(
        "ProductActiveWorkoutRecoveryRequested"
    )
}

/// One process-wide runtime ensures the WatchKit delegate and SwiftUI scene
/// reattach to the same platform session and coordinator after a crash.
final class ProductWorkoutRuntime: @unchecked Sendable {
    static let shared = ProductWorkoutRuntime()

    let store: BadmintonWorkoutFileStore
    let coordinator: BadmintonWorkoutSessionCoordinator
    let transferOutbox: BadmintonWorkoutTransferOutbox
    let transferSnapshotStore: BadmintonWorkoutTransferSnapshotStore

    private let recoveryLock = NSLock()
    private var recoveryTask: Task<BadmintonWorkoutSessionSnapshot?, Error>?

    private init() {
        let store = BadmintonWorkoutFileStore(baseDirectory: Self.workoutDirectory)
        let stateStore = BadmintonWorkoutTransferStateStore(
            baseDirectory: Self.productDataDirectory.appendingPathComponent(
                "WorkoutTransferState",
                isDirectory: true
            )
        )
#if targetEnvironment(simulator)
        let platform: any WorkoutPlatformSession = SimulatorWorkoutPlatformSession()
#else
        let platform: any WorkoutPlatformSession = HealthKitWorkoutPlatformSession()
#endif
        self.store = store
        coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)
        transferOutbox = BadmintonWorkoutTransferOutbox(
            workoutStore: store,
            stateStore: stateStore
        )
        transferSnapshotStore = BadmintonWorkoutTransferSnapshotStore(
            baseDirectory: Self.productDataDirectory.appendingPathComponent(
                "ConnectivityOutgoing",
                isDirectory: true
            )
        )
    }

    func beginActiveWorkoutRecovery() {
        let didCreateTask = recoveryLock.withLock {
            guard recoveryTask == nil else { return false }
            let coordinator = coordinator
            recoveryTask = Task {
                try await coordinator.recoverActiveSession()
            }
            return true
        }
        if didCreateTask {
            NotificationCenter.default.post(
                name: .productActiveWorkoutRecoveryRequested,
                object: nil
            )
        }
    }

    func activeRecoveryTask() -> Task<BadmintonWorkoutSessionSnapshot?, Error>? {
        recoveryLock.withLock { recoveryTask }
    }

    private static var workoutDirectory: URL {
        productDataDirectory.appendingPathComponent("Workouts", isDirectory: true)
    }

    private static var productDataDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("ProductData", isDirectory: true)
    }
}
