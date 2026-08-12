import XCTest
@testable import BadmintonCore

final class BadmintonWorkoutRecordTests: XCTestCase {
    func testActiveDurationExcludesPausedTimeAndSimulatorCannotClaimHealthSave() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var record = BadmintonWorkoutRecord(
            provenance: .simulatorSynthetic,
            startedAt: start,
            healthAuthorizationState: .simulated
        )

        record.markStarted(at: start)
        XCTAssertEqual(record.activeDuration(at: start.addingTimeInterval(10)), 10)
        record.markPaused(at: start.addingTimeInterval(10))
        XCTAssertEqual(record.activeDuration(at: start.addingTimeInterval(20)), 10)
        record.markResumed(at: start.addingTimeInterval(20))
        record.markCompleted(
            at: start.addingTimeInterval(35),
            result: .init(healthWriteState: .simulatedNotSaved)
        )

        XCTAssertEqual(record.accumulatedActiveDurationSeconds, 25)
        XCTAssertEqual(record.lifecycleState, .completed)
        XCTAssertNoThrow(try record.validate())

        record.healthWriteState = .saved
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? BadmintonWorkoutValidationError,
                .simulatedWorkoutMarkedHealthKitSaved
            )
        }
    }

    func testInvalidHealthMetricsAreRejected() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var record = BadmintonWorkoutRecord(
            provenance: .healthKitDevice,
            startedAt: start,
            lifecycleState: .active,
            lastResumedAt: start,
            healthAuthorizationState: .authorized,
            healthWriteState: .collecting,
            healthMetrics: .init(
                averageHeartRateBeatsPerMinute: 150,
                maximumHeartRateBeatsPerMinute: 140
            )
        )
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(
                error as? BadmintonWorkoutValidationError,
                .maximumHeartRateBelowAverage
            )
        }

        record.healthMetrics = .init(activeEnergyKilocalories: -.infinity)
        XCTAssertThrowsError(try record.validate()) { error in
            XCTAssertEqual(error as? BadmintonWorkoutValidationError, .invalidEnergy)
        }
    }
}
