import XCTest
@testable import OBDCore

final class IdleWatchdogTests: XCTestCase {

    private let connected = Date(timeIntervalSince1970: 1_000_000)

    func testStaysConnectedWhileSamplesArrive() {
        let watchdog = IdleWatchdog(timeout: 600)
        let now = connected.addingTimeInterval(3600)
        // A drive produces samples continuously, so it never times out.
        XCTAssertFalse(watchdog.shouldDisconnect(
            now: now,
            lastActivity: now.addingTimeInterval(-2),
            connectedAt: connected
        ))
    }

    func testDisconnectsAfterTimeoutWithNoSamples() {
        let watchdog = IdleWatchdog(timeout: 600)
        let last = connected
        XCTAssertFalse(watchdog.shouldDisconnect(
            now: last.addingTimeInterval(599), lastActivity: last, connectedAt: connected))
        XCTAssertTrue(watchdog.shouldDisconnect(
            now: last.addingTimeInterval(600), lastActivity: last, connectedAt: connected))
    }

    /// A vehicle that never answers should still time out, measured from connect.
    func testTimesOutEvenWithNoSampleEverReceived() {
        let watchdog = IdleWatchdog(timeout: 600)
        XCTAssertFalse(watchdog.shouldDisconnect(
            now: connected.addingTimeInterval(300), lastActivity: nil, connectedAt: connected))
        XCTAssertTrue(watchdog.shouldDisconnect(
            now: connected.addingTimeInterval(601), lastActivity: nil, connectedAt: connected))
    }

    func testRemainingCountsDown() {
        let watchdog = IdleWatchdog(timeout: 600)
        let now = connected.addingTimeInterval(100)
        XCTAssertEqual(watchdog.remaining(now: now, lastActivity: connected, connectedAt: connected),
                       500, accuracy: 0.001)
        XCTAssertEqual(watchdog.remaining(now: connected.addingTimeInterval(900),
                                          lastActivity: connected, connectedAt: connected),
                       0, accuracy: 0.001)
    }
}
