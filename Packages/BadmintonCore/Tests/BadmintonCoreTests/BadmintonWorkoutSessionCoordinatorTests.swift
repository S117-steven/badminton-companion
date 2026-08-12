import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutSessionCoordinatorTests: XCTestCase {
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
    private var eventHandler: (@Sendable (WorkoutPlatformEvent) -> Void)?
    private var commandLog: [String] = []
    private var invalidated = false

    init(
        authorization: WorkoutHealthAuthorizationState,
        provenance: WorkoutDataProvenance,
        endResult: WorkoutPlatformEndResult
    ) {
        self.authorization = authorization
        self.provenance = provenance
        self.endResult = endResult
    }

    func requestAuthorization() async -> WorkoutHealthAuthorizationState {
        authorization
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
