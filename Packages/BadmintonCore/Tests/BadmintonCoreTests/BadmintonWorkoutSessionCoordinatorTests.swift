import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutSessionCoordinatorTests: XCTestCase {
    func testRecoveryRebindsMatchingCheckpointAndInterruptsOnlyStaleRecords() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let recoveredAt = start.addingTimeInterval(60)
        var matching = BadmintonWorkoutRecord(
            provenance: .healthKitDevice,
            startedAt: start,
            healthAuthorizationState: .authorized
        )
        matching.markStarted(at: start)
        matching.checkpointActiveDuration(at: start.addingTimeInterval(10))
        try await store.create(matching)

        let staleStart = start.addingTimeInterval(-600)
        var stale = BadmintonWorkoutRecord(
            provenance: .healthKitDevice,
            startedAt: staleStart,
            healthAuthorizationState: .authorized
        )
        stale.markStarted(at: staleStart)
        stale.checkpointActiveDuration(at: staleStart.addingTimeInterval(7))
        try await store.create(stale)

        let platform = ControlledWorkoutPlatform(
            authorization: .authorized,
            provenance: .healthKitDevice,
            endResult: .init(healthWriteState: .saved),
            recoveryResult: .init(
                startedAt: start,
                recoveredAt: recoveredAt,
                activeDurationSeconds: 42,
                activeState: .running
            )
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)

        let recoverySnapshot = try await coordinator.recoverActiveSession()
        let snapshot = try XCTUnwrap(recoverySnapshot)
        let restoredMatching = try await store.load(id: matching.id)
        let restoredStale = try await store.load(id: stale.id)
        let commands = await platform.commands()

        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(snapshot.record?.id, matching.id)
        XCTAssertEqual(snapshot.activeDurationSeconds, 42)
        XCTAssertEqual(restoredMatching.accumulatedActiveDurationSeconds, 42)
        XCTAssertEqual(restoredMatching.lastResumedAt, recoveredAt)
        XCTAssertEqual(restoredMatching.healthWriteState, .collecting)
        XCTAssertEqual(restoredStale.lifecycleState, .interrupted)
        XCTAssertEqual(restoredStale.accumulatedActiveDurationSeconds, 7)
        XCTAssertEqual(commands, ["recover"])
    }

    func testRecoveryCreatesRecordWhenLocalCheckpointIsMissing() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let recoveredAt = start.addingTimeInterval(80)
        let platform = ControlledWorkoutPlatform(
            authorization: .authorized,
            provenance: .healthKitDevice,
            endResult: .init(healthWriteState: .saved),
            recoveryResult: .init(
                startedAt: start,
                recoveredAt: recoveredAt,
                activeDurationSeconds: 51,
                activeState: .paused
            )
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)

        let recoverySnapshot = try await coordinator.recoverActiveSession()
        let snapshot = try XCTUnwrap(recoverySnapshot)
        let records = try await store.list()

        XCTAssertEqual(snapshot.phase, .paused)
        XCTAssertEqual(snapshot.activeDurationSeconds, 51)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.provenance, .healthKitDevice)
        XCTAssertEqual(records.first?.startedAt, start)
        XCTAssertEqual(records.first?.lifecycleState, .paused)
        XCTAssertEqual(records.first?.healthWriteState, .collecting)
    }

    func testMissingPlatformRecoveryLeavesCheckpointForSafeLocalClosure() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var local = BadmintonWorkoutRecord(
            provenance: .healthKitDevice,
            startedAt: start,
            healthAuthorizationState: .authorized
        )
        local.markStarted(at: start)
        local.checkpointActiveDuration(at: start.addingTimeInterval(12))
        try await store.create(local)
        let platform = ControlledWorkoutPlatform(
            authorization: .authorized,
            provenance: .healthKitDevice,
            endResult: .init(healthWriteState: .saved)
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)

        let result = try await coordinator.recoverActiveSession()
        let coordinatorSnapshot = await coordinator.currentSnapshot()
        let beforeClosure = try await store.load(id: local.id)
        let closed = try await store.recoverUnfinished(
            at: start.addingTimeInterval(86_400)
        )

        XCTAssertNil(result)
        XCTAssertEqual(coordinatorSnapshot.phase, .idle)
        XCTAssertEqual(beforeClosure.lifecycleState, .active)
        XCTAssertEqual(closed.first?.lifecycleState, .interrupted)
        XCTAssertEqual(closed.first?.accumulatedActiveDurationSeconds, 12)
    }

    func testStartPauseResumeMetricsAndEndPersistOneConsistentWorkout() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let platform = ControlledWorkoutPlatform(
            authorization: .simulated,
            provenance: .simulatorSynthetic,
            endResult: .init(healthWriteState: .simulatedNotSaved)
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let running = try await coordinator.start(at: start)
        XCTAssertEqual(running.phase, .running)
        let checkpoint = try await coordinator.checkpoint(
            at: start.addingTimeInterval(5)
        )
        XCTAssertEqual(checkpoint.activeDurationSeconds, 5)
        _ = try await coordinator.pause(at: start.addingTimeInterval(10))
        _ = try await coordinator.resume(at: start.addingTimeInterval(20))
        await platform.emit(
            .metrics(
                .init(
                    recordedAt: start.addingTimeInterval(25),
                    currentHeartRateBeatsPerMinute: 151,
                    averageHeartRateBeatsPerMinute: 142,
                    maximumHeartRateBeatsPerMinute: 166,
                    activeEnergyKilocalories: 123.4,
                    totalEnergyKilocalories: 151.2
                )
            )
        )
        try await waitUntil {
            await coordinator.currentSnapshot().record?.healthMetrics
                .currentHeartRateBeatsPerMinute == 151
        }
        let completed = try await coordinator.end(at: start.addingTimeInterval(35))
        let id = try XCTUnwrap(completed.record?.id)
        let restored = try await store.load(id: id)

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(restored.accumulatedActiveDurationSeconds, 25)
        XCTAssertEqual(restored.lifecycleState, .completed)
        XCTAssertEqual(restored.healthWriteState, .simulatedNotSaved)
        XCTAssertEqual(restored.healthMetrics.maximumHeartRateBeatsPerMinute, 166)
        let commands = await platform.commands()
        XCTAssertEqual(commands, ["start", "pause", "resume", "end"])
    }

    func testDeniedAuthorizationIsExplicitAndCreatesNoWorkout() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let platform = ControlledWorkoutPlatform(
            authorization: .denied,
            provenance: .healthKitDevice,
            endResult: .init(healthWriteState: .failed)
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)

        do {
            _ = try await coordinator.start()
            XCTFail("Expected authorization failure")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutSessionError,
                .authorizationNotGranted(.denied)
            )
        }

        let snapshot = await coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .failed)
        XCTAssertEqual(snapshot.failure?.code, "health_authorization_denied")
        let records = try await store.list()
        XCTAssertTrue(records.isEmpty)
        let commands = await platform.commands()
        XCTAssertEqual(commands, [])
    }

    func testPlatformFailureInterruptsAndPersistsWorkout() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let platform = ControlledWorkoutPlatform(
            authorization: .simulated,
            provenance: .simulatorSynthetic,
            endResult: .init(healthWriteState: .simulatedNotSaved)
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)
        let start = Date()
        let running = try await coordinator.start(at: start)
        let id = try XCTUnwrap(running.record?.id)

        await platform.emit(
            .failure(.init(code: "platform_lost", message: "Synthetic platform stopped"))
        )
        try await waitUntil { await coordinator.currentSnapshot().phase == .failed }
        let restored = try await store.load(id: id)

        XCTAssertEqual(restored.lifecycleState, .interrupted)
        XCTAssertEqual(restored.failureCode, "platform_lost")
        XCTAssertEqual(restored.healthWriteState, .simulatedNotSaved)
        let wasInvalidated = await platform.wasInvalidated()
        XCTAssertTrue(wasInvalidated)
    }

    func testOutOfOrderTransitionDateIsRejectedWithoutMutatingState() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BadmintonWorkoutFileStore(baseDirectory: root)
        let platform = ControlledWorkoutPlatform(
            authorization: .simulated,
            provenance: .simulatorSynthetic,
            endResult: .init(healthWriteState: .simulatedNotSaved)
        )
        let coordinator = BadmintonWorkoutSessionCoordinator(store: store, platform: platform)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await coordinator.start(at: start)

        do {
            _ = try await coordinator.pause(at: start.addingTimeInterval(-1))
            XCTFail("Expected invalid transition date")
        } catch {
            XCTAssertEqual(
                error as? BadmintonWorkoutSessionError,
                .invalidTransitionDate
            )
        }
        let snapshot = await coordinator.currentSnapshot(at: start)
        XCTAssertEqual(snapshot.phase, .running)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let started = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - started > timeoutNanoseconds {
                XCTFail("Timed out waiting for workout state")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private actor ControlledWorkoutPlatform: WorkoutPlatformSession {
    nonisolated let provenance: WorkoutDataProvenance
    private let authorization: WorkoutHealthAuthorizationState
    private let endResult: WorkoutPlatformEndResult
    private let recoveryResult: WorkoutPlatformRecoveryResult?
    private var eventHandler: (@Sendable (WorkoutPlatformEvent) -> Void)?
    private var commandLog: [String] = []
    private var invalidated = false

    init(
        authorization: WorkoutHealthAuthorizationState,
        provenance: WorkoutDataProvenance,
        endResult: WorkoutPlatformEndResult,
        recoveryResult: WorkoutPlatformRecoveryResult? = nil
    ) {
        self.authorization = authorization
        self.provenance = provenance
        self.endResult = endResult
        self.recoveryResult = recoveryResult
    }

    func requestAuthorization() async -> WorkoutHealthAuthorizationState {
        authorization
    }

    func recoverActive(
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws -> WorkoutPlatformRecoveryResult? {
        commandLog.append("recover")
        eventHandler = onEvent
        return recoveryResult
    }

    func start(
        at date: Date,
        onEvent: @escaping @Sendable (WorkoutPlatformEvent) -> Void
    ) async throws {
        commandLog.append("start")
        eventHandler = onEvent
    }

    func pause(at date: Date) async throws {
        commandLog.append("pause")
    }

    func resume(at date: Date) async throws {
        commandLog.append("resume")
    }

    func end(at date: Date) async throws -> WorkoutPlatformEndResult {
        commandLog.append("end")
        eventHandler = nil
        return endResult
    }

    func invalidate() async {
        invalidated = true
        eventHandler = nil
    }

    func emit(_ event: WorkoutPlatformEvent) {
        eventHandler?(event)
    }

    func commands() -> [String] {
        commandLog
    }

    func wasInvalidated() -> Bool {
        invalidated
    }
}
