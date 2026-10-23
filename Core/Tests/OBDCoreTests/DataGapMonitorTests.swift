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
}
