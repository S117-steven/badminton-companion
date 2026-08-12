import Foundation

public enum BadmintonWorkoutSessionPhase: String, Equatable, Sendable {
    case idle
    case recovering
    case requestingAuthorization = "requesting_authorization"
    case starting
    case running
    case pausing
    case paused
    case resuming
    case ending
    case completed
    case failed
}

public struct BadmintonWorkoutSessionSnapshot: Equatable, Sendable {
    public let phase: BadmintonWorkoutSessionPhase
    public let record: BadmintonWorkoutRecord?
    public let activeDurationSeconds: TimeInterval
    public let failure: WorkoutPlatformFailure?

    public init(
        phase: BadmintonWorkoutSessionPhase,
        record: BadmintonWorkoutRecord?,
        activeDurationSeconds: TimeInterval,
        failure: WorkoutPlatformFailure?
    ) {
        self.phase = phase
        self.record = record
        self.activeDurationSeconds = activeDurationSeconds
        self.failure = failure
    }
}

public enum BadmintonWorkoutSessionError: Error, Equatable, Sendable {
    case sessionAlreadyActive
    case sessionNotRunning
    case sessionNotPaused
    case sessionCannotEnd
    case invalidTransitionDate
    case invalidPlatformRecovery
    case authorizationNotGranted(WorkoutHealthAuthorizationState)
}

public actor BadmintonWorkoutSessionCoordinator {
    private let store: BadmintonWorkoutFileStore
    private let platform: any WorkoutPlatformSession

    private var phase: BadmintonWorkoutSessionPhase = .idle
    private var record: BadmintonWorkoutRecord?
    private var failure: WorkoutPlatformFailure?
    private var eventContinuation: AsyncStream<WorkoutPlatformEvent>.Continuation?
    private var eventTask: Task<Void, Never>?

    public init(
        store: BadmintonWorkoutFileStore,
        platform: any WorkoutPlatformSession
    ) {
        self.store = store
        self.platform = platform
    }

    /// Reattaches the one HealthKit session that can survive an application
    /// crash to its local record. This must be triggered from WatchKit's
    /// active-workout recovery callback on the platform side.
    @discardableResult
    public func recoverActiveSession() async throws -> BadmintonWorkoutSessionSnapshot? {
        guard phase == .idle else {
            throw BadmintonWorkoutSessionError.sessionAlreadyActive
        }
        phase = .recovering
        failure = nil
        prepareEventStream()

        do {
            guard let recovery = try await platform.recoverActive(
                onEvent: { [continuation = eventContinuation] event in
                    continuation?.yield(event)
                }
            ) else {
                phase = .idle
                finishEventStream()
                return nil
            }
            guard platform.provenance == .healthKitDevice,
                  recovery.startedAt <= recovery.recoveredAt,
                  recovery.activeDurationSeconds.isFinite,
                  recovery.activeDurationSeconds >= 0,
                  recovery.activeDurationSeconds <= recovery.recoveredAt
                    .timeIntervalSince(recovery.startedAt) + 5 else {
                throw BadmintonWorkoutSessionError.invalidPlatformRecovery
            }

            let unfinished = try await store.unfinished()
            let matchingRecord = unfinished
                .filter { $0.provenance == .healthKitDevice }
                .min {
                    abs($0.startedAt.timeIntervalSince(recovery.startedAt))
                        < abs($1.startedAt.timeIntervalSince(recovery.startedAt))
                }
                .flatMap { candidate in
                    abs(candidate.startedAt.timeIntervalSince(recovery.startedAt)) <= 10
                        ? candidate
                        : nil
                }

            var restored = matchingRecord ?? BadmintonWorkoutRecord(
                provenance: .healthKitDevice,
                startedAt: recovery.startedAt,
                healthAuthorizationState: .authorized
            )
            try restored.restoreFromRecoveredPlatform(
                at: recovery.recoveredAt,
                activeDurationSeconds: recovery.activeDurationSeconds,
                activeState: recovery.activeState
            )
            if matchingRecord == nil {
                try await store.create(restored)
            } else {
                try await store.save(restored)
            }
            record = restored
            _ = try await store.recoverUnfinished(
                at: recovery.recoveredAt,
                excluding: [restored.id]
            )
            phase = recovery.activeState == .running ? .running : .paused
            return snapshot(at: recovery.recoveredAt)
        } catch {
            await fail(
                .init(code: "workout_recovery_failed", message: String(describing: error)),
                at: Date()
            )
            throw error
        }
    }

    @discardableResult
    public func start(at date: Date = Date()) async throws -> BadmintonWorkoutSessionSnapshot {
        guard ![.recovering, .requestingAuthorization, .starting, .running, .pausing, .paused,
                .resuming, .ending].contains(phase) else {
            throw BadmintonWorkoutSessionError.sessionAlreadyActive
        }
        phase = .requestingAuthorization
        failure = nil
        let authorization = await platform.requestAuthorization()
        guard authorization.permitsWorkoutStart else {
            phase = .failed
            failure = .init(
                code: "health_authorization_\(authorization.rawValue)",
                message: "Health access is required to start and save a badminton workout."
            )
            throw BadmintonWorkoutSessionError.authorizationNotGranted(authorization)
        }

        var newRecord = BadmintonWorkoutRecord(
            provenance: platform.provenance,
            startedAt: date,
            healthAuthorizationState: authorization
        )
        try await store.create(newRecord)
        record = newRecord
        phase = .starting
        prepareEventStream()

        do {
            try await platform.start(at: date) { [continuation = eventContinuation] event in
                continuation?.yield(event)
            }
            newRecord.markStarted(at: date)
            record = newRecord
            phase = .running
            try await store.save(newRecord)
            return snapshot(at: date)
        } catch {
            let platformFailure = WorkoutPlatformFailure(
                code: "workout_start_failed",
                message: String(describing: error)
            )
            await fail(platformFailure, at: date)
            throw error
        }
    }

    @discardableResult
    public func pause(at date: Date = Date()) async throws -> BadmintonWorkoutSessionSnapshot {
        guard phase == .running, let record else {
            throw BadmintonWorkoutSessionError.sessionNotRunning
        }
        guard date >= record.updatedAt else {
            throw BadmintonWorkoutSessionError.invalidTransitionDate
        }
        phase = .pausing
        do {
            try await platform.pause(at: date)
        } catch {
            phase = .running
            throw error
        }
        guard var record = self.record else {
            throw BadmintonWorkoutSessionError.sessionNotRunning
        }
        record.markPaused(at: date)
        self.record = record
        do {
            try await store.save(record)
            phase = .paused
            return snapshot(at: date)
        } catch {
            await fail(
                .init(code: "workout_checkpoint_failed", message: String(describing: error)),
                at: date
            )
            throw error
        }
    }

    @discardableResult
    public func resume(at date: Date = Date()) async throws -> BadmintonWorkoutSessionSnapshot {
        guard phase == .paused, let record else {
            throw BadmintonWorkoutSessionError.sessionNotPaused
        }
        guard date >= record.updatedAt else {
            throw BadmintonWorkoutSessionError.invalidTransitionDate
        }
        phase = .resuming
        do {
            try await platform.resume(at: date)
        } catch {
            phase = .paused
            throw error
        }
        guard var record = self.record else {
            throw BadmintonWorkoutSessionError.sessionNotPaused
        }
        record.markResumed(at: date)
        self.record = record
        do {
            try await store.save(record)
            phase = .running
            return snapshot(at: date)
        } catch {
            await fail(
                .init(code: "workout_checkpoint_failed", message: String(describing: error)),
                at: date
            )
            throw error
        }
    }

    @discardableResult
    public func end(at date: Date = Date()) async throws -> BadmintonWorkoutSessionSnapshot {
        guard [.running, .paused].contains(phase), let record else {
            throw BadmintonWorkoutSessionError.sessionCannotEnd
        }
        guard date >= record.updatedAt else {
            throw BadmintonWorkoutSessionError.invalidTransitionDate
        }
        phase = .ending
        let result: WorkoutPlatformEndResult
        do {
            result = try await platform.end(at: date)
        } catch {
            let platformFailure = WorkoutPlatformFailure(
                code: "workout_finish_failed",
                message: String(describing: error)
            )
            await fail(platformFailure, at: date)
            throw error
        }
        guard var record = self.record else {
            throw BadmintonWorkoutSessionError.sessionCannotEnd
        }
        record.markCompleted(at: max(date, record.startedAt), result: result)
        self.record = record
        do {
            try await store.save(record)
            phase = .completed
            finishEventStream()
            return snapshot(at: date)
        } catch {
            await fail(
                .init(code: "workout_checkpoint_failed", message: String(describing: error)),
                at: date
            )
            throw error
        }
    }

    @discardableResult
    public func interrupt(
        at date: Date = Date(),
        code: String = "application_interrupted",
        message: String = "The workout was interrupted before it could be saved."
    ) async -> BadmintonWorkoutSessionSnapshot {
        await fail(.init(code: code, message: message), at: date)
        return snapshot(at: date)
    }

    public func currentSnapshot(at date: Date = Date()) -> BadmintonWorkoutSessionSnapshot {
        snapshot(at: date)
    }

    @discardableResult
    public func checkpoint(
        at date: Date = Date()
    ) async throws -> BadmintonWorkoutSessionSnapshot {
        guard phase == .running, var record else {
            throw BadmintonWorkoutSessionError.sessionNotRunning
        }
        guard date >= record.updatedAt else {
            throw BadmintonWorkoutSessionError.invalidTransitionDate
        }
        record.checkpointActiveDuration(at: date)
        try await store.save(record)
        self.record = record
        return snapshot(at: date)
    }

    public func reset() async throws {
        guard ![.recovering, .requestingAuthorization, .starting, .running, .pausing, .paused,
                .resuming, .ending].contains(phase) else {
            throw BadmintonWorkoutSessionError.sessionAlreadyActive
        }
        await platform.invalidate()
        finishEventStream()
        phase = .idle
        record = nil
        failure = nil
    }

    private func prepareEventStream() {
        finishEventStream()
        let (stream, continuation) = AsyncStream<WorkoutPlatformEvent>.makeStream()
        eventContinuation = continuation
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    private func finishEventStream() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventTask?.cancel()
        eventTask = nil
    }

    private func receive(_ event: WorkoutPlatformEvent) async {
        switch event {
        case .metrics(let update):
            guard [.recovering, .running, .pausing, .paused, .resuming, .ending]
                .contains(phase),
                  var record else { return }
            record.healthMetrics.merge(update)
            record.lastMetricAt = max(update.recordedAt, record.lastMetricAt ?? record.startedAt)
            do {
                try await store.save(record)
                self.record = record
            } catch {
                await fail(
                    .init(code: "workout_checkpoint_failed", message: String(describing: error)),
                    at: Date()
                )
            }
        case .failure(let platformFailure):
            await fail(platformFailure, at: Date())
        }
    }

    private func fail(_ platformFailure: WorkoutPlatformFailure, at date: Date) async {
        guard ![.idle, .completed, .failed].contains(phase) else { return }
        failure = platformFailure
        await platform.invalidate()
        if var record {
            record.markInterrupted(at: date, failure: platformFailure)
            do {
                try await store.save(record)
                self.record = record
            } catch {
                failure = .init(
                    code: "\(platformFailure.code)+checkpoint_failed",
                    message: "\(platformFailure.message); \(error)"
                )
            }
        }
        phase = .failed
        finishEventStream()
    }

    private func snapshot(at date: Date) -> BadmintonWorkoutSessionSnapshot {
        .init(
            phase: phase,
            record: record,
            activeDurationSeconds: record?.activeDuration(at: date) ?? 0,
            failure: failure
        )
    }
}
