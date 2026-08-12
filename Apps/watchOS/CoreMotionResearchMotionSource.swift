@preconcurrency import CoreMotion
import BadmintonCore
import Foundation

/// Physical-device adapter. Core Motion timestamps are preserved and each
/// sensor stream computes its interval independently before entering the shared
/// capture pipeline.
final class CoreMotionResearchMotionSource: ResearchMotionSource, @unchecked Sendable {
    let provenance = ResearchDataProvenance.physicalSensor

    private static let metersPerSecondSquaredPerG = 9.80665

    private let manager: CMMotionManager
    private let deliveryQueue: OperationQueue
    private let stateLock = NSLock()

    private var isRunning = false
    private var failureReported = false
    private var captureStartTimestamp = 0.0
    private var nextSequenceNumber: UInt64 = 0
    private var lastTimestampBySource: [ResearchSensorSource: TimeInterval] = [:]

    init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
        let queue = OperationQueue()
        queue.name = "badminton.research.core-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        deliveryQueue = queue
    }

    func start(
        configuration: ResearchMotionSourceConfiguration,
        onEvent: @escaping @Sendable (ResearchMotionSourceEvent) -> Void
    ) async throws {
        guard configuration.requestedIntervalSeconds > 0 else {
            throw ResearchMotionSourceFailure(
                code: "invalid_interval",
                message: "Requested Core Motion interval must be positive."
            )
        }

        let unavailableSources = unavailableSourceNames()
        guard unavailableSources.isEmpty else {
            throw ResearchMotionSourceFailure(
                code: "required_motion_source_unavailable",
                message: "Unavailable Core Motion sources: \(unavailableSources.joined(separator: ", "))."
            )
        }

        try stateLock.withLock {
            guard !isRunning else {
                throw ResearchMotionSourceFailure(
                    code: "core_motion_already_active",
                    message: "Core Motion capture is already active."
                )
            }
            isRunning = true
            failureReported = false
            captureStartTimestamp = ProcessInfo.processInfo.systemUptime
            nextSequenceNumber = 0
            lastTimestampBySource.removeAll(keepingCapacity: true)
        }

        let interval = configuration.requestedIntervalSeconds
        manager.accelerometerUpdateInterval = interval
        manager.gyroUpdateInterval = interval
        manager.deviceMotionUpdateInterval = interval

        manager.startAccelerometerUpdates(to: deliveryQueue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.report(error: error, source: .accelerometer, onEvent: onEvent)
                return
            }
            guard let data,
                  let timing = self.nextTiming(
                    source: .accelerometer,
                    timestamp: data.timestamp
                  ) else { return }
            let acceleration = data.acceleration
            onEvent(.samples([
                ResearchMotionSample(
                    sequenceNumber: timing.sequenceNumber,
                    source: .accelerometer,
                    monotonicTimestampSeconds: data.timestamp,
                    elapsedTimeSeconds: timing.elapsed,
                    actualIntervalSeconds: timing.actualInterval,
                    accelerationMetersPerSecondSquared: .init(
                        x: acceleration.x * Self.metersPerSecondSquaredPerG,
                        y: acceleration.y * Self.metersPerSecondSquaredPerG,
                        z: acceleration.z * Self.metersPerSecondSquaredPerG
                    )
                ),
            ]))
        }

        manager.startGyroUpdates(to: deliveryQueue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.report(error: error, source: .gyroscope, onEvent: onEvent)
                return
            }
            guard let data,
                  let timing = self.nextTiming(
                    source: .gyroscope,
                    timestamp: data.timestamp
                  ) else { return }
            let rotation = data.rotationRate
            onEvent(.samples([
                ResearchMotionSample(
                    sequenceNumber: timing.sequenceNumber,
                    source: .gyroscope,
                    monotonicTimestampSeconds: data.timestamp,
                    elapsedTimeSeconds: timing.elapsed,
                    actualIntervalSeconds: timing.actualInterval,
                    angularVelocityRadiansPerSecond: .init(
                        x: rotation.x,
                        y: rotation.y,
                        z: rotation.z
                    )
                ),
            ]))
        }

        manager.startDeviceMotionUpdates(to: deliveryQueue) { [weak self] data, error in
            guard let self else { return }
            if let error {
                self.report(error: error, source: .deviceMotion, onEvent: onEvent)
                return
            }
            guard let data,
                  let timing = self.nextTiming(
                    source: .deviceMotion,
                    timestamp: data.timestamp
                  ) else { return }
            let rotation = data.rotationRate
            let gravity = data.gravity
            let userAcceleration = data.userAcceleration
            let attitude = data.attitude.quaternion
            onEvent(.samples([
                ResearchMotionSample(
                    sequenceNumber: timing.sequenceNumber,
                    source: .deviceMotion,
                    monotonicTimestampSeconds: data.timestamp,
                    elapsedTimeSeconds: timing.elapsed,
                    actualIntervalSeconds: timing.actualInterval,
                    angularVelocityRadiansPerSecond: .init(
                        x: rotation.x,
                        y: rotation.y,
                        z: rotation.z
                    ),
                    gravity: .init(x: gravity.x, y: gravity.y, z: gravity.z),
                    userAccelerationMetersPerSecondSquared: .init(
                        x: userAcceleration.x * Self.metersPerSecondSquaredPerG,
                        y: userAcceleration.y * Self.metersPerSecondSquaredPerG,
                        z: userAcceleration.z * Self.metersPerSecondSquaredPerG
                    ),
                    attitudeQuaternion: .init(
                        x: attitude.x,
                        y: attitude.y,
                        z: attitude.z,
                        w: attitude.w
                    )
                ),
            ]))
        }
    }

    func stop() async {
        let shouldStop = stateLock.withLock {
            let wasRunning = isRunning
            isRunning = false
            return wasRunning
        }
        guard shouldStop else { return }

        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopDeviceMotionUpdates()
        deliveryQueue.cancelAllOperations()
    }

    private func unavailableSourceNames() -> [String] {
        var names: [String] = []
        if !manager.isAccelerometerAvailable { names.append("accelerometer") }
        if !manager.isGyroAvailable { names.append("gyroscope") }
        if !manager.isDeviceMotionAvailable { names.append("device_motion") }
        return names
    }

    private func nextTiming(
        source: ResearchSensorSource,
        timestamp: TimeInterval
    ) -> (sequenceNumber: UInt64, elapsed: TimeInterval, actualInterval: TimeInterval?)? {
        stateLock.withLock {
            guard isRunning else { return nil }
            let sequenceNumber = nextSequenceNumber
            nextSequenceNumber += 1
            let previousTimestamp = lastTimestampBySource.updateValue(timestamp, forKey: source)
            return (
                sequenceNumber,
                max(0, timestamp - captureStartTimestamp),
                previousTimestamp.map { max(0, timestamp - $0) }
            )
        }
    }

    private func report(
        error: Error,
        source: ResearchSensorSource,
        onEvent: @escaping @Sendable (ResearchMotionSourceEvent) -> Void
    ) {
        let shouldReport = stateLock.withLock {
            guard isRunning, !failureReported else { return false }
            failureReported = true
            return true
        }
        guard shouldReport else { return }
        onEvent(
            .failure(
                .init(
                    code: "core_motion_\(source.rawValue)_failed",
                    message: error.localizedDescription
                )
            )
        )
    }
}
