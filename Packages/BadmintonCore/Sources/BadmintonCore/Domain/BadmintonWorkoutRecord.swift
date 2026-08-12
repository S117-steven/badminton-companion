import Foundation

public enum WorkoutDataProvenance: String, Codable, Equatable, Sendable {
    case healthKitDevice = "healthkit_device"
    case simulatorSynthetic = "simulator_synthetic"
    case automatedTestFixture = "automated_test_fixture"
}

public enum WorkoutLifecycleState: String, Codable, Equatable, Sendable {
    case starting
    case active
    case paused
    case completed
    case interrupted
}

public enum WorkoutHealthAuthorizationState: String, Codable, Equatable, Sendable {
    case notDetermined = "not_determined"
    case authorized
    case denied
    case unavailable
    case requestFailed = "request_failed"
    case simulated

    public var permitsWorkoutStart: Bool {
        self == .authorized || self == .simulated
    }
}

public enum WorkoutHealthWriteState: String, Codable, Equatable, Sendable {
    case notStarted = "not_started"
    case collecting
    case saved
    case failed
    case simulatedNotSaved = "simulated_not_saved"
}

public struct WorkoutHealthMetrics: Codable, Equatable, Sendable {
    public var currentHeartRateBeatsPerMinute: Double?
    public var averageHeartRateBeatsPerMinute: Double?
    public var maximumHeartRateBeatsPerMinute: Double?
    public var activeEnergyKilocalories: Double?
    public var totalEnergyKilocalories: Double?

    public init(
        currentHeartRateBeatsPerMinute: Double? = nil,
        averageHeartRateBeatsPerMinute: Double? = nil,
        maximumHeartRateBeatsPerMinute: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        totalEnergyKilocalories: Double? = nil
    ) {
        self.currentHeartRateBeatsPerMinute = currentHeartRateBeatsPerMinute
        self.averageHeartRateBeatsPerMinute = averageHeartRateBeatsPerMinute
        self.maximumHeartRateBeatsPerMinute = maximumHeartRateBeatsPerMinute
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.totalEnergyKilocalories = totalEnergyKilocalories
    }

    public mutating func merge(_ update: WorkoutMetricUpdate) {
        if let value = update.currentHeartRateBeatsPerMinute {
            currentHeartRateBeatsPerMinute = value
        }
        if let value = update.averageHeartRateBeatsPerMinute {
            averageHeartRateBeatsPerMinute = value
        }
        if let value = update.maximumHeartRateBeatsPerMinute {
            maximumHeartRateBeatsPerMinute = value
        }
        if let value = update.activeEnergyKilocalories {
            activeEnergyKilocalories = value
        }
        if let value = update.totalEnergyKilocalories {
            totalEnergyKilocalories = value
        }
    }
}

public enum BadmintonWorkoutValidationError: Error, Equatable, Sendable {
    case endBeforeStart
    case invalidActiveDuration
    case missingEndForTerminalState
    case unexpectedEndForLiveState
    case invalidUpdateTimestamp
    case invalidLastResumedAt
    case invalidHeartRate
    case maximumHeartRateBelowAverage
    case invalidEnergy
    case simulatedWorkoutMarkedHealthKitSaved
}

/// A versioned, algorithm-neutral workout record. Hit and smash fields are
/// deliberately absent until the real-data gates authorize those algorithms.
public struct BadmintonWorkoutRecord: Codable, Equatable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let provenance: WorkoutDataProvenance
    public let startedAt: Date
    public var endedAt: Date?
    public var lifecycleState: WorkoutLifecycleState
    public var accumulatedActiveDurationSeconds: TimeInterval
    public var lastResumedAt: Date?
    public var healthAuthorizationState: WorkoutHealthAuthorizationState
    public var healthWriteState: WorkoutHealthWriteState
    public var healthWorkoutUUID: UUID?
    public var healthMetrics: WorkoutHealthMetrics
    public var lastMetricAt: Date?
    public var failureCode: String?
    public var failureMessage: String?
    public var updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: UUID = UUID(),
        provenance: WorkoutDataProvenance,
        startedAt: Date,
        endedAt: Date? = nil,
        lifecycleState: WorkoutLifecycleState = .starting,
        accumulatedActiveDurationSeconds: TimeInterval = 0,
        lastResumedAt: Date? = nil,
        healthAuthorizationState: WorkoutHealthAuthorizationState,
        healthWriteState: WorkoutHealthWriteState = .notStarted,
        healthWorkoutUUID: UUID? = nil,
        healthMetrics: WorkoutHealthMetrics = .init(),
        lastMetricAt: Date? = nil,
        failureCode: String? = nil,
        failureMessage: String? = nil,
        updatedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.provenance = provenance
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lifecycleState = lifecycleState
        self.accumulatedActiveDurationSeconds = accumulatedActiveDurationSeconds
        self.lastResumedAt = lastResumedAt
        self.healthAuthorizationState = healthAuthorizationState
        self.healthWriteState = healthWriteState
        self.healthWorkoutUUID = healthWorkoutUUID
        self.healthMetrics = healthMetrics
        self.lastMetricAt = lastMetricAt
        self.failureCode = failureCode
        self.failureMessage = failureMessage
        self.updatedAt = updatedAt ?? startedAt
    }

    public func activeDuration(at date: Date) -> TimeInterval {
        guard lifecycleState == .active, let lastResumedAt else {
            return accumulatedActiveDurationSeconds
        }
        return accumulatedActiveDurationSeconds + max(0, date.timeIntervalSince(lastResumedAt))
    }

    public mutating func markStarted(at date: Date) {
        lifecycleState = .active
        lastResumedAt = date
        healthWriteState = provenance == .healthKitDevice ? .collecting : .notStarted
        updatedAt = date
    }

    public mutating func markPaused(at date: Date) {
        accumulatedActiveDurationSeconds = activeDuration(at: date)
        lastResumedAt = nil
        lifecycleState = .paused
        updatedAt = date
    }

    public mutating func checkpointActiveDuration(at date: Date) {
        guard lifecycleState == .active else { return }
        accumulatedActiveDurationSeconds = activeDuration(at: date)
        lastResumedAt = date
        updatedAt = date
    }

    public mutating func markResumed(at date: Date) {
        lifecycleState = .active
        lastResumedAt = date
        updatedAt = date
    }

    public mutating func markCompleted(
        at date: Date,
        result: WorkoutPlatformEndResult
    ) {
        accumulatedActiveDurationSeconds = activeDuration(at: date)
        lastResumedAt = nil
        endedAt = date
        lifecycleState = .completed
        healthWriteState = result.healthWriteState
        healthWorkoutUUID = result.healthWorkoutUUID
        updatedAt = date
    }

    public mutating func markInterrupted(
        at date: Date,
        failure: WorkoutPlatformFailure
    ) {
        accumulatedActiveDurationSeconds = activeDuration(at: date)
        lastResumedAt = nil
        endedAt = max(date, startedAt)
        lifecycleState = .interrupted
        if healthWriteState == .collecting || healthWriteState == .notStarted {
            healthWriteState = provenance == .healthKitDevice ? .failed : .simulatedNotSaved
        }
        failureCode = failure.code
        failureMessage = failure.message
        updatedAt = max(date, startedAt)
    }

    public func validate() throws {
        if let endedAt, endedAt < startedAt {
            throw BadmintonWorkoutValidationError.endBeforeStart
        }
        if updatedAt < startedAt {
            throw BadmintonWorkoutValidationError.invalidUpdateTimestamp
        }
        if let lastMetricAt, lastMetricAt < startedAt {
            throw BadmintonWorkoutValidationError.invalidUpdateTimestamp
        }
        guard accumulatedActiveDurationSeconds.isFinite,
              accumulatedActiveDurationSeconds >= 0 else {
            throw BadmintonWorkoutValidationError.invalidActiveDuration
        }
        let isTerminal = lifecycleState == .completed || lifecycleState == .interrupted
        if isTerminal, endedAt == nil {
            throw BadmintonWorkoutValidationError.missingEndForTerminalState
        }
        if !isTerminal, endedAt != nil {
            throw BadmintonWorkoutValidationError.unexpectedEndForLiveState
        }
        if lifecycleState == .active {
            guard let lastResumedAt,
                  lastResumedAt >= startedAt,
                  lastResumedAt <= updatedAt else {
                throw BadmintonWorkoutValidationError.invalidLastResumedAt
            }
        } else if lastResumedAt != nil {
            throw BadmintonWorkoutValidationError.invalidLastResumedAt
        }
        let heartRates = [
            healthMetrics.currentHeartRateBeatsPerMinute,
            healthMetrics.averageHeartRateBeatsPerMinute,
            healthMetrics.maximumHeartRateBeatsPerMinute,
        ].compactMap { $0 }
        if heartRates.contains(where: { !$0.isFinite || $0 <= 0 }) {
            throw BadmintonWorkoutValidationError.invalidHeartRate
        }
        if let average = healthMetrics.averageHeartRateBeatsPerMinute,
           let maximum = healthMetrics.maximumHeartRateBeatsPerMinute,
           maximum < average {
            throw BadmintonWorkoutValidationError.maximumHeartRateBelowAverage
        }
        let energies = [
            healthMetrics.activeEnergyKilocalories,
            healthMetrics.totalEnergyKilocalories,
        ].compactMap { $0 }
        if energies.contains(where: { !$0.isFinite || $0 < 0 }) {
            throw BadmintonWorkoutValidationError.invalidEnergy
        }
        if provenance != .healthKitDevice, healthWriteState == .saved {
            throw BadmintonWorkoutValidationError.simulatedWorkoutMarkedHealthKitSaved
        }
    }
}
