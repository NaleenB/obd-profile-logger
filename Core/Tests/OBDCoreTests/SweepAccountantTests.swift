import XCTest
@testable import OBDCore

final class SweepAccountantTests: XCTestCase {

    private let planned: [UInt8] = [0x01, 0x02, 0x03, 0x04]

    func testCompleteCycleCountsAttemptsAndAnswers() {
        var accountant = SweepAccountant()
        for lid in planned {
            accountant.recordAttempt(lid)
            accountant.recordAnswer(lid)
        }
        let summary = accountant.completeCycle(planned: planned)
        XCTAssertEqual(summary?.cycle, 1)
        XCTAssertEqual(summary?.attempted, 4)
        XCTAssertEqual(summary?.answered, 4)
        XCTAssertEqual(summary?.missing, [])
    }

    /// A timeout is an attempt with no answer.
    func testTimeoutCountsAsAttemptNotAnswer() {
        var accountant = SweepAccountant()
        for lid in planned {
            accountant.recordAttempt(lid)
            if lid != 0x03 { accountant.recordAnswer(lid) }
        }
        let summary = accountant.completeCycle(planned: planned)
        XCTAssertEqual(summary?.attempted, 4)
        XCTAssertEqual(summary?.answered, 3)
    }

    /// A malformed reply is likewise attempted but unanswered.
    func testMalformedReplyCountsAsUnanswered() {
        var accountant = SweepAccountant()
        accountant.recordAttempt(0x01)
        accountant.recordAnswer(0x01)
        accountant.recordAttempt(0x02)   // request sent, nothing parseable back
        let summary = accountant.completeCycle(planned: [0x01, 0x02])
        XCTAssertEqual(summary?.attempted, 2)
        XCTAssertEqual(summary?.answered, 1)
    }

    /// Counters must not carry into the next cycle.
    func testCountsResetBetweenCycles() {
        var accountant = SweepAccountant()
        for lid in planned {
            accountant.recordAttempt(lid)
            accountant.recordAnswer(lid)
        }
        _ = accountant.completeCycle(planned: planned)

        accountant.recordAttempt(0x01)
        accountant.recordAnswer(0x01)
        let second = accountant.completeCycle(planned: planned)
        XCTAssertEqual(second?.cycle, 2)
        XCTAssertEqual(second?.attempted, 1, "answered must not accumulate across cycles")
        XCTAssertEqual(second?.answered, 1)
        XCTAssertEqual(second?.missing, [0x02, 0x03, 0x04])
    }

    func testIdentifiersNeverRequestedAreReportedMissing() {
        var accountant = SweepAccountant()
        accountant.recordAttempt(0x01)
        let summary = accountant.completeCycle(planned: planned)
        XCTAssertEqual(summary?.missing, [0x02, 0x03, 0x04])
    }

    func testNoAttemptsProducesNoSummary() {
        var accountant = SweepAccountant()
        XCTAssertNil(accountant.completeCycle(planned: planned))
    }

    func testResetClearsCycleCount() {
        var accountant = SweepAccountant()
        accountant.recordAttempt(0x01)
        _ = accountant.completeCycle(planned: planned)
        accountant.reset()

        accountant.recordAttempt(0x01)
        XCTAssertEqual(accountant.completeCycle(planned: planned)?.cycle, 1)
    }
}
