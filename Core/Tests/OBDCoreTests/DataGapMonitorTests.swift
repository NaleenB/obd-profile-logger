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
        XCTAssertEqual(transition, .ended(gapSeconds: 100))
        XCTAssertFalse(monitor.isInGap)
    }

    func testFinishReportsAnOpenGap() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start.addingTimeInterval(30), lastSampleAt: start)
        let transition = monitor.finish(now: start.addingTimeInterval(200))
        XCTAssertEqual(transition, .ended(gapSeconds: 200))
    }

    func testFinishWithNoGapDoesNothing() {
        var monitor = DataGapMonitor(threshold: 10)
        _ = monitor.update(now: start, lastSampleAt: start)
        XCTAssertNil(monitor.finish(now: start.addingTimeInterval(1)))
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
        XCTAssertEqual(closed, .ended(gapSeconds: 303))
        XCTAssertNil(monitor.update(now: resumedAt, lastSampleAt: resumedAt))
    }
}
