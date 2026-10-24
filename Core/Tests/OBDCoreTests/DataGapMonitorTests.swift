import XCTest
@testable import OBDCore

final class DataGapMonitorTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testNoGapWhileSamplesKeepArriving() {
        var monitor = DataGapMonitor(threshold: 10)
        XCTAssertNil(monitor.update(now: start, lastSampleAt: start))
        XCTAssertNil(monitor.update(now: start.addingTimeInterval(5), lastSampleAt: start.addingTimeInterval(4)))
        XCTAssertFalse(monitor.isInGap)
    }

    func testGapStartsOnceAfterThreshold() {
        var monitor = DataGapMonitor(threshold: 10)
        let last = start
        XCTAssertNil(monitor.update(now: start.addingTimeInterval(9), lastSampleAt: last))

        let transition = monitor.update(now: start.addingTimeInterval(11), lastSampleAt: last)
        XCTAssertEqual(transition, .started(quietFor: 11))
        XCTAssertTrue(monitor.isInGap)

        // Repeated calls do not spam.
        XCTAssertNil(monitor.update(now: start.addingTimeInterval(12), lastSampleAt: last))
        XCTAssertNil(monitor.update(now: start.addingTimeInterval(60), lastSampleAt: last))
    }

    func testGapEndsWhenDataResumes() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start.addingTimeInterval(11), lastSampleAt: start)

        let resumedAt = start.addingTimeInterval(100)
        let transition = monitor.update(now: resumedAt, lastSampleAt: resumedAt)
        XCTAssertEqual(transition, .ended(gapSeconds: 100, reason: .resumed))
        XCTAssertFalse(monitor.isInGap)
    }

    func testFinishReportsAnOpenGap() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start.addingTimeInterval(30), lastSampleAt: start)
        let transition = monitor.finish(now: start.addingTimeInterval(200), reason: .recordingStopped)
        XCTAssertEqual(transition, .ended(gapSeconds: 200, reason: .recordingStopped))
    }

    func testFinishWithNoGapDoesNothing() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start, lastSampleAt: start)
        XCTAssertNil(monitor.finish(now: start.addingTimeInterval(1), reason: .recordingStopped))
    }

    /// The reported defect: a link drop while the vehicle was already silent was
    /// logged as `data_resumed`. The reason is now carried by the transition, so
    /// only a real sample can produce `.resumed`.
    func testLinkLossClosesTheGapWithoutClaimingResumption() {
        var monitor = DataGapMonitor(threshold: 10)
        XCTAssertEqual(monitor.update(now: start.addingTimeInterval(30), lastSampleAt: start),
                       .started(quietFor: 30))

        let closed = monitor.finish(now: start.addingTimeInterval(45), reason: .linkDown)
        XCTAssertEqual(closed, .ended(gapSeconds: 45, reason: .linkDown))
        XCTAssertFalse(monitor.isInGap)
    }

    /// A stall is also not a resumption.
    func testStallClosesTheGapWithItsOwnReason() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start.addingTimeInterval(30), lastSampleAt: start)
        XCTAssertEqual(monitor.finish(now: start.addingTimeInterval(70), reason: .stalled),
                       .ended(gapSeconds: 70, reason: .stalled))
    }

    /// Only `update` observing a fresh sample may end a gap by resumption.
    func testOnlyAnArrivingSampleIsAResumption() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start.addingTimeInterval(30), lastSampleAt: start)
        let arrived = start.addingTimeInterval(40)
        XCTAssertEqual(monitor.update(now: arrived, lastSampleAt: arrived),
                       .ended(gapSeconds: 40, reason: .resumed))
    }

    func testNoLastSampleMeansNoJudgement() {
        var monitor = DataGapMonitor(threshold: 10)
        XCTAssertNil(monitor.update(now: start, lastSampleAt: nil))
        XCTAssertFalse(monitor.isInGap)
    }

    /// The contract the poll loop relies on: `update` is called every iteration
    /// with the last sample time *unchanged* while the car is asleep.
    ///
    /// This is the case that was broken in the app — the call sat after a
    /// successful sample, where the silence it measures had just been reset to
    /// zero, so a sleeping ECU produced no `data_gap` event at all.
    func testASilentCarProducesOneGapAcrossManyIterations() {
        var monitor = DataGapMonitor(threshold: 10)
        let lastSample = start
        var transitions: [DataGapMonitor.Transition] = []

        // Five minutes of quiet, one call per iteration.
        for second in stride(from: 0.0, through: 300.0, by: 3.0) {
            if let transition = monitor.update(
                now: start.addingTimeInterval(second), lastSampleAt: lastSample) {
                transitions.append(transition)
            }
        }

        XCTAssertEqual(transitions, [.started(quietFor: 12)])

        // The car answers again: the gap closes exactly once.
        let resumedAt = start.addingTimeInterval(303)
        let closed = monitor.update(now: resumedAt, lastSampleAt: resumedAt)
        XCTAssertEqual(closed, .ended(gapSeconds: 303, reason: .resumed))
        XCTAssertNil(monitor.update(now: resumedAt, lastSampleAt: resumedAt))
    }
}
