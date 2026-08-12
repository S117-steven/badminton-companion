import Foundation

public struct SensorVector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct SensorQuaternion: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    public let w: Double

    public init(x: Double, y: Double, z: Double, w: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public enum ResearchSensorSource: String, Codable, Equatable, Sendable {
    case accelerometer
    case gyroscope
    case deviceMotion = "device_motion"
}

/// A timestamped sensor record. Optional channels allow independent raw sensor
/// callbacks to retain their own timestamps instead of forcing interpolation.
public struct ResearchMotionSample: Codable, Equatable, Sendable {
    public let sequenceNumber: UInt64
    public let source: ResearchSensorSource
    public let monotonicTimestampSeconds: Double
    public let elapsedTimeSeconds: Double
    public let actualIntervalSeconds: Double?

    /// SI units: m/s².
    public let accelerationMetersPerSecondSquared: SensorVector3?

    /// SI units: rad/s.
    public let angularVelocityRadiansPerSecond: SensorVector3?

    /// Unitless gravity vector supplied by device motion.
    public let gravity: SensorVector3?

    /// SI units: m/s² after conversion at the platform adapter boundary.
    public let userAccelerationMetersPerSecondSquared: SensorVector3?

    public let attitudeQuaternion: SensorQuaternion?

    public init(
        sequenceNumber: UInt64,
        source: ResearchSensorSource,
        monotonicTimestampSeconds: Double,
        elapsedTimeSeconds: Double,
        actualIntervalSeconds: Double? = nil,
        accelerationMetersPerSecondSquared: SensorVector3? = nil,
        angularVelocityRadiansPerSecond: SensorVector3? = nil,
        gravity: SensorVector3? = nil,
        userAccelerationMetersPerSecondSquared: SensorVector3? = nil,
        attitudeQuaternion: SensorQuaternion? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.source = source
        self.monotonicTimestampSeconds = monotonicTimestampSeconds
        self.elapsedTimeSeconds = elapsedTimeSeconds
        self.actualIntervalSeconds = actualIntervalSeconds
        self.accelerationMetersPerSecondSquared = accelerationMetersPerSecondSquared
        self.angularVelocityRadiansPerSecond = angularVelocityRadiansPerSecond
        self.gravity = gravity
        self.userAccelerationMetersPerSecondSquared = userAccelerationMetersPerSecondSquared
        self.attitudeQuaternion = attitudeQuaternion
    }
}
