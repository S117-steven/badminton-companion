import BadmintonCore
import Foundation

/// Deterministic UI plumbing for Simulator only. It never writes HealthKit and
/// every resulting record is permanently marked simulator_synthetic.
actor SimulatorWorkoutPlatformSession: WorkoutPlatformSession {
    nonisolated let provenance = WorkoutDataProvenance.simulatorSynthetic

    private var eventHandler: (@Sendable (WorkoutPlatformEvent) -> Void)?
    private var timerTask: Task<Void, Never>?
    private var isRunning = false
    private var activeTickCount = 0
    private var heartRateTotal = 0.0
    private var heartRateMaximum: Double?

    func requestAuthorization() async -> WorkoutHealthAuthorizationState {
        .simulated
    }

    func recoverActive(
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws -> WorkoutPlatformRecoveryResult? {
        nil
    }

    func start(
        at date: Date,
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws {
        eventHandler = onEvent
        isRunning = true
        activeTickCount = 0
        heartRateTotal = 0
        heartRateMaximum = nil
        emitTick()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                await self?.emitTick()
            }
        }
    }

    func pause(at date: Date) async throws {
        isRunning = false
    }

    func resume(at date: Date) async throws {
        isRunning = true
    }

    func end(at date: Date) async throws -> WorkoutPlatformEndResult {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        eventHandler = nil
        return .init(healthWriteState: .simulatedNotSaved)
    }

    func invalidate() async {
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        eventHandler = nil
    }

    private func emitTick() {
        guard isRunning else { return }
        activeTickCount += 1
        let heartRate = 118 + Double(activeTickCount % 29)
        heartRateTotal += heartRate
        heartRateMaximum = max(heartRateMaximum ?? heartRate, heartRate)
        let activeEnergy = Double(activeTickCount) * 0.12
        eventHandler?(
            .metrics(
                .init(
                    currentHeartRateBeatsPerMinute: heartRate,
                    averageHeartRateBeatsPerMinute: heartRateTotal / Double(activeTickCount),
                    maximumHeartRateBeatsPerMinute: heartRateMaximum,
                    activeEnergyKilocalories: activeEnergy,
                    totalEnergyKilocalories: activeEnergy + Double(activeTickCount) * 0.025
                )
            )
        )
    }
}
