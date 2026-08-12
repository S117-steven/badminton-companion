import Foundation

public struct WorkoutMetricUpdate: Equatable, Sendable {
    public var recordedAt: Date
    public var currentHeartRateBeatsPerMinute: Double?
    public var averageHeartRateBeatsPerMinute: Double?
    public var maximumHeartRateBeatsPerMinute: Double?
    public var activeEnergyKilocalories: Double?
    public var totalEnergyKilocalories: Double?

    public init(
        recordedAt: Date = Date(),
        currentHeartRateBeatsPerMinute: Double? = nil,
        averageHeartRateBeatsPerMinute: Double? = nil,
        maximumHeartRateBeatsPerMinute: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        totalEnergyKilocalories: Double? = nil
    ) {
        self.recordedAt = recordedAt
        self.currentHeartRateBeatsPerMinute = currentHeartRateBeatsPerMinute
        self.averageHeartRateBeatsPerMinute = averageHeartRateBeatsPerMinute
        self.maximumHeartRateBeatsPerMinute = maximumHeartRateBeatsPerMinute
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.totalEnergyKilocalories = totalEnergyKilocalories
    }
}

public struct WorkoutPlatformFailure: Error, Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum WorkoutPlatformEvent: Equatable, Sendable {
    case metrics(WorkoutMetricUpdate)
    case failure(WorkoutPlatformFailure)
}

public struct WorkoutPlatformEndResult: Equatable, Sendable {
    public let healthWriteState: WorkoutHealthWriteState
    public let healthWorkoutUUID: UUID?

    public init(
        healthWriteState: WorkoutHealthWriteState,
        healthWorkoutUUID: UUID? = nil
    ) {
        self.healthWriteState = healthWriteState
        self.healthWorkoutUUID = healthWorkoutUUID
    }
}

public protocol WorkoutPlatformSession: Sendable {
    var provenance: WorkoutDataProvenance { get }

    func requestAuthorization() async -> WorkoutHealthAuthorizationState
    func start(
        at date: Date,
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws
    func pause(at date: Date) async throws
    func resume(at date: Date) async throws
    func end(at date: Date) async throws -> WorkoutPlatformEndResult
    func invalidate() async
}
