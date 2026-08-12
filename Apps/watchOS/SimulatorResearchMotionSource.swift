import BadmintonCore
import Foundation

actor SimulatorResearchMotionSource: ResearchMotionSource {
    nonisolated let provenance = ResearchDataProvenance.simulatorSynthetic

    private var productionTask: Task<Void, Never>?

    func start(
        configuration: ResearchMotionSourceConfiguration,
        onEvent: @escaping @Sendable (ResearchMotionSourceEvent) -> Void
    ) async throws {
        guard productionTask == nil else {
            throw ResearchMotionSourceFailure(
                code: "simulator_source_already_active",
                message: "Simulator source is already active."
            )
        }
        guard configuration.requestedIntervalSeconds > 0 else {
            throw ResearchMotionSourceFailure(
                code: "invalid_interval",
                message: "Requested interval must be positive."
            )
        }

        let interval = configuration.requestedIntervalSeconds
        productionTask = Task {
            let baseTimestamp = ProcessInfo.processInfo.systemUptime
            var tick: UInt64 = 0
            while !Task.isCancelled {
                let elapsed = Double(tick) * interval
                let phase = Double(tick) * 0.12
                let firstSequence = tick * 3
                let actualInterval: TimeInterval? = tick == 0 ? nil : interval
                let samples = [
                    ResearchMotionSample(
                        sequenceNumber: firstSequence,
                        source: .accelerometer,
                        monotonicTimestampSeconds: baseTimestamp + elapsed,
                        elapsedTimeSeconds: elapsed,
                        actualIntervalSeconds: actualInterval,
                        accelerationMetersPerSecondSquared: .init(
                            x: sin(phase) * 4,
                            y: cos(phase * 0.8) * 3,
                            z: 9.80665 + sin(phase * 0.5)
                        )
                    ),
                    ResearchMotionSample(
                        sequenceNumber: firstSequence + 1,
                        source: .gyroscope,
                        monotonicTimestampSeconds: baseTimestamp + elapsed,
                        elapsedTimeSeconds: elapsed,
                        actualIntervalSeconds: actualInterval,
                        angularVelocityRadiansPerSecond: .init(
                            x: sin(phase * 1.2),
                            y: cos(phase) * 1.5,
                            z: sin(phase * 0.7) * 2
                        )
                    ),
                    ResearchMotionSample(
                        sequenceNumber: firstSequence + 2,
                        source: .deviceMotion,
                        monotonicTimestampSeconds: baseTimestamp + elapsed,
                        elapsedTimeSeconds: elapsed,
                        actualIntervalSeconds: actualInterval,
                        angularVelocityRadiansPerSecond: .init(
                            x: sin(phase * 1.2),
                            y: cos(phase) * 1.5,
                            z: sin(phase * 0.7) * 2
                        ),
                        gravity: .init(x: 0, y: 0, z: -1),
                        userAccelerationMetersPerSecondSquared: .init(
                            x: sin(phase) * 2,
                            y: cos(phase) * 1.5,
                            z: sin(phase * 0.5)
                        ),
                        attitudeQuaternion: .init(
                            x: 0,
                            y: sin(phase * 0.05),
                            z: 0,
                            w: cos(phase * 0.05)
                        )
                    ),
                ]
                onEvent(.samples(samples))
                tick += 1
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    func stop() async {
        productionTask?.cancel()
        await productionTask?.value
        productionTask = nil
    }
}

