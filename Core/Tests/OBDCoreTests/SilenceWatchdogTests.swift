import XCTest
@testable import OBDCore

final class SilenceWatchdogTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func watchdog() -> SilenceWatchdog {
        SilenceWatchdog(noticeAfter: 5, quietAfter: 15, quietInterval: 3)
    }

    /// A car that is answering is not silent, however long the session runs.
    func testFreshSamplesAreNotSilence() {
        let watchdog = watchdog()
        let now = start.addingTimeInterval(600)
        let lastSample = now.addingTimeInterval(-1)
        XCTAssertFalse(watchdog.isNoticeable(now: now, reference: lastSample))
        XCTAssertFalse(watchdog.shouldPollQuietly(now: now, reference: lastSample))
    }

    /// The notice arrives at five seconds, the quiet cycle at fifteen. Until
    /// then the full sweep is still worth sending.
    func testThresholdsAreOrdered() {
        let watchdog = watchdog()
        let lastSample = start

        XCTAssertFalse(watchdog.isNoticeable(
            now: start.addingTimeInterval(4.9), reference: lastSample))
        XCTAssertTrue(watchdog.isNoticeable(
            now: start.addingTimeInterval(5), reference: lastSample))
        XCTAssertFalse(watchdog.shouldPollQuietly(
            now: start.addingTimeInterval(10), reference: lastSample))
        XCTAssertTrue(watchdog.shouldPollQuietly(
            now: start.addingTimeInterval(15), reference: lastSample))
    }

    /// Before the first sample the connection time is the reference: a car that
    /// never answered is the case this whole type exists for.
    func testReferenceFallsBackToTheConnection() {
        let watchdog = watchdog()
        let connected = start
        XCTAssertFalse(watchdog.isNoticeable(
            now: start.addingTimeInterval(4), reference: connected))
        XCTAssertTrue(watchdog.isNoticeable(
            now: start.addingTimeInterval(6), reference: connected))
        XCTAssertTrue(watchdog.shouldPollQuietly(
            now: start.addingTimeInterval(20), reference: connected))
    }

    /// No reference at all means the link is not up, so nothing is judged.
    func testNoReferenceIsNoJudgement() {
        let watchdog = watchdog()
        let now = start.addingTimeInterval(1000)
        XCTAssertNil(watchdog.quietFor(now: now, reference: nil))
        XCTAssertFalse(watchdog.isNoticeable(now: now, reference: nil))
        XCTAssertFalse(watchdog.shouldPollQuietly(now: now, reference: nil))
    }

    /// A clock that appears to move backwards — a restored session, or a
    /// correction — must not produce a negative age or a spurious notice.
    func testReferenceInTheFutureClamps() {
        let watchdog = watchdog()
        let now = start
        let future = start.addingTimeInterval(30)
        XCTAssertEqual(watchdog.quietFor(now: now, reference: future), 0)
        XCTAssertFalse(watchdog.isNoticeable(now: now, reference: future))
        XCTAssertFalse(watchdog.shouldPollQuietly(now: now, reference: future))
    }

    /// The quiet interval has to be long enough to be worth the battery and
    /// short enough that a restart is noticed promptly.
    func testQuietIntervalIsASensiblePace() {
        let watchdog = watchdog()
        XCTAssertGreaterThanOrEqual(watchdog.quietInterval, 1)
        XCTAssertLessThanOrEqual(watchdog.quietInterval, 10)
        XCTAssertGreaterThan(watchdog.quietAfter, watchdog.noticeAfter)
    }
}

final class QuietProbeTests: XCTestCase {

    private func signal(_ pid: String) -> VehicleProfile.StandardSignal {
        VehicleProfile.StandardSignal(
            pid: pid, name: pid, unit: "", bytes: 1,
            factor: 1, offset: 0, decimals: 0)
    }

    func testEngineSpeedIsPreferred() {
        let chosen = QuietProbe.choose(from: [signal("42"), signal("0C")])
        XCTAssertEqual(chosen?.pid, "0C")
    }

    /// A profile without rpm must still send something. The old guard returned
    /// before any request, so a waking car could never leave quiet mode.
    func testProfileWithoutEngineSpeedStillGetsAProbe() {
        let chosen = QuietProbe.choose(from: [signal("42")])
        XCTAssertEqual(chosen?.pid, "42")
    }

    func testNoSignalsHasNoProbe() {
        XCTAssertNil(QuietProbe.choose(from: []))
    }
}
