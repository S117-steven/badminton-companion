@preconcurrency import HealthKit
import BadmintonCore
import Foundation

enum HealthKitWorkoutPlatformError: Error {
    case healthDataUnavailable
    case authorizationRequired
    case sessionAlreadyExists
    case sessionMissing
    case collectionStartFailed
    case collectionEndFailed
    case workoutSaveFailed
    case recoveredSessionHasWrongActivity
    case recoveredSessionHasInvalidState
    case recoveredSessionMissingStartDate
}

actor HealthKitWorkoutPlatformSession: WorkoutPlatformSession {
    nonisolated let provenance = WorkoutDataProvenance.healthKitDevice

    private let healthStore = HKHealthStore()
    private var authorizationState = WorkoutHealthAuthorizationState.notDetermined
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var sessionDelegate: HealthKitSessionDelegateProxy?
    private var builderDelegate: HealthKitBuilderDelegateProxy?
    private var eventHandler: (@Sendable (WorkoutPlatformEvent) -> Void)?
    private var stopContinuation: CheckedContinuation<Void, Error>?

    func requestAuthorization() async -> WorkoutHealthAuthorizationState {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return .unavailable
        }
        let workoutType = HKObjectType.workoutType()
        let readTypes = Set<HKObjectType>([
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.basalEnergyBurned),
        ])
        do {
            try await healthStore.requestAuthorization(
                toShare: [workoutType],
                read: readTypes
            )
            switch healthStore.authorizationStatus(for: workoutType) {
            case .sharingAuthorized:
                authorizationState = .authorized
            case .sharingDenied:
                authorizationState = .denied
            case .notDetermined:
                authorizationState = .notDetermined
            @unknown default:
                authorizationState = .requestFailed
            }
        } catch {
            authorizationState = .requestFailed
        }
        return authorizationState
    }

    func recoverActive(
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws -> WorkoutPlatformRecoveryResult? {
        guard session == nil else {
            throw HealthKitWorkoutPlatformError.sessionAlreadyExists
        }
        guard let recoveredSession = try await recoverSession() else { return nil }
        let recoveredBuilder = recoveredSession.associatedWorkoutBuilder()
        bind(
            session: recoveredSession,
            builder: recoveredBuilder,
            onEvent: onEvent
        )

        guard recoveredSession.workoutConfiguration.activityType == .badminton else {
            await discardCurrentSession()
            throw HealthKitWorkoutPlatformError.recoveredSessionHasWrongActivity
        }
        let activeState: WorkoutPlatformActiveState
        switch recoveredSession.state {
        case .running:
            activeState = .running
        case .paused:
            activeState = .paused
        default:
            await discardCurrentSession()
            throw HealthKitWorkoutPlatformError.recoveredSessionHasInvalidState
        }
        guard let startedAt = recoveredSession.startDate ?? recoveredBuilder.startDate else {
            await discardCurrentSession()
            throw HealthKitWorkoutPlatformError.recoveredSessionMissingStartDate
        }
        authorizationState = .authorized
        let recoveredAt = Date()
        return .init(
            startedAt: startedAt,
            recoveredAt: recoveredAt,
            activeDurationSeconds: recoveredBuilder.elapsedTime(at: recoveredAt),
            activeState: activeState
        )
    }

    func start(
        at date: Date,
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws {
        guard authorizationState == .authorized else {
            throw HealthKitWorkoutPlatformError.authorizationRequired
        }
        guard session == nil else {
            throw HealthKitWorkoutPlatformError.sessionAlreadyExists
        }

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .badminton
        configuration.locationType = .unknown
        let session = try HKWorkoutSession(
            healthStore: healthStore,
            configuration: configuration
        )
        let builder = session.associatedWorkoutBuilder()
        bind(session: session, builder: builder, onEvent: onEvent)

        session.startActivity(with: date)
        do {
            try await beginCollection(builder, at: date)
        } catch {
            await discardCurrentSession()
            throw error
        }
    }

    func pause(at date: Date) async throws {
        guard let session else { throw HealthKitWorkoutPlatformError.sessionMissing }
        session.pause()
    }

    func resume(at date: Date) async throws {
        guard let session else { throw HealthKitWorkoutPlatformError.sessionMissing }
        session.resume()
    }

    func end(at date: Date) async throws -> WorkoutPlatformEndResult {
        guard let session, let builder else {
            throw HealthKitWorkoutPlatformError.sessionMissing
        }
        try await stop(session, at: date)
        try await endCollection(builder, at: date)
        let workout = try await finishWorkout(builder)
        session.end()
        clearReferences()
        return .init(
            healthWriteState: .saved,
            healthWorkoutUUID: workout?.uuid
        )
    }

    func invalidate() async {
        await discardCurrentSession()
    }

    private func beginCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.beginCollection(withStart: date) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitWorkoutPlatformError.collectionStartFailed)
                }
            }
        }
    }

    private func recoverSession() async throws -> HKWorkoutSession? {
        try await withCheckedThrowingContinuation { continuation in
            healthStore.recoverActiveWorkoutSession { session, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: session)
                }
            }
        }
    }

    private func bind(
        session: HKWorkoutSession,
        builder: HKLiveWorkoutBuilder,
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) {
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: session.workoutConfiguration
        )
        let sessionDelegate = HealthKitSessionDelegateProxy(
            onStopped: { [weak self] in
                Task { await self?.handleStopped() }
            },
            onFailure: { [weak self] error in
                Task { await self?.handleFailure(error) }
            }
        )
        let builderDelegate = HealthKitBuilderDelegateProxy(onMetrics: onEvent)
        session.delegate = sessionDelegate
        builder.delegate = builderDelegate
        self.session = session
        self.builder = builder
        self.sessionDelegate = sessionDelegate
        self.builderDelegate = builderDelegate
        eventHandler = onEvent
    }

    private func stop(_ session: HKWorkoutSession, at date: Date) async throws {
        if session.state == .stopped { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stopContinuation = continuation
            session.stopActivity(with: date)
        }
    }

    private func endCollection(_ builder: HKLiveWorkoutBuilder, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: date) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitWorkoutPlatformError.collectionEndFailed)
                }
            }
        }
    }

    private func finishWorkout(_ builder: HKLiveWorkoutBuilder) async throws -> HKWorkout? {
        try await withCheckedThrowingContinuation { continuation in
            builder.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    // Apple documents nil workout + nil error as a successful
                    // save while the device is locked.
                    continuation.resume(returning: workout)
                }
            }
        }
    }

    private func handleStopped() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    private func handleFailure(_ error: Error) {
        stopContinuation?.resume(throwing: error)
        stopContinuation = nil
        eventHandler?(
            .failure(
                .init(code: "healthkit_session_failed", message: error.localizedDescription)
            )
        )
    }

    private func discardCurrentSession() async {
        stopContinuation?.resume(throwing: HealthKitWorkoutPlatformError.workoutSaveFailed)
        stopContinuation = nil
        builder?.discardWorkout()
        session?.end()
        clearReferences()
    }

    private func clearReferences() {
        session = nil
        builder = nil
        sessionDelegate = nil
        builderDelegate = nil
        eventHandler = nil
    }
}

private final class HealthKitSessionDelegateProxy: NSObject, HKWorkoutSessionDelegate,
    @unchecked Sendable {
    private let onStopped: @Sendable () -> Void
    private let onFailure: @Sendable (Error) -> Void

    init(
        onStopped: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.onStopped = onStopped
        self.onFailure = onFailure
    }

    func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        if toState == .stopped {
            onStopped()
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        onFailure(error)
    }
}

private final class HealthKitBuilderDelegateProxy: NSObject, HKLiveWorkoutBuilderDelegate,
    @unchecked Sendable {
    private let onEvent: @Sendable (WorkoutPlatformEvent) -> Void

    init(onMetrics: @escaping @Sendable (WorkoutPlatformEvent) -> Void) {
        onEvent = onMetrics
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRateType = HKQuantityType(.heartRate)
        let activeEnergyType = HKQuantityType(.activeEnergyBurned)
        let basalEnergyType = HKQuantityType(.basalEnergyBurned)
        let heartRateUnit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let energyUnit = HKUnit.kilocalorie()

        let heartRate = workoutBuilder.statistics(for: heartRateType)
        let activeEnergy = workoutBuilder.statistics(for: activeEnergyType)?
            .sumQuantity()?.doubleValue(for: energyUnit)
        let basalEnergy = workoutBuilder.statistics(for: basalEnergyType)?
            .sumQuantity()?.doubleValue(for: energyUnit)
        onEvent(
            .metrics(
                .init(
                    currentHeartRateBeatsPerMinute: heartRate?
                        .mostRecentQuantity()?.doubleValue(for: heartRateUnit),
                    averageHeartRateBeatsPerMinute: heartRate?
                        .averageQuantity()?.doubleValue(for: heartRateUnit),
                    maximumHeartRateBeatsPerMinute: heartRate?
                        .maximumQuantity()?.doubleValue(for: heartRateUnit),
                    activeEnergyKilocalories: activeEnergy,
                    totalEnergyKilocalories: activeEnergy.map { $0 + (basalEnergy ?? 0) }
                )
            )
        )
    }
}
