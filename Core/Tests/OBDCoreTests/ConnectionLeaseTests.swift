import XCTest
@testable import OBDCore

final class ConnectionLeaseTests: XCTestCase {

    func testCurrentAttemptMayProceed() {
        var lease = ConnectionLease<Int>()
        lease.claim(1)
        XCTAssertEqual(lease.checkpoint(1, isCurrent: true), .proceed)
    }

    /// A reconnect may be awaiting a BLE connection when the user presses
    /// Disconnect. `disconnect()` closes the transport and releases ownership,
    /// so the stale attempt must stop but must not close anything else.
    func testAttemptStopsAfterUserDisconnectWithoutClosingTheTransportAgain() {
        var lease = ConnectionLease<Int>()
        lease.claim(1)
        lease.release()

        XCTAssertEqual(lease.checkpoint(1, isCurrent: false),
                       .aborted(shutdownTransport: false))
    }

    /// The replacement attempt owns the transport. When the superseded attempt
    /// finally returns from its await, its cleanup must not kill the new link.
    func testSupersededAttemptLeavesItsReplacementConnected() {
        var lease = ConnectionLease<Int>()
        lease.claim(1)
        lease.claim(2)

        XCTAssertEqual(lease.checkpoint(1, isCurrent: false),
                       .aborted(shutdownTransport: false))
        XCTAssertEqual(lease.checkpoint(2, isCurrent: true), .proceed)
    }

    /// Nothing has replaced a cancelled attempt, so it is the only owner of any
    /// connection it managed to open and must close it.
    func testCancelledSoleOwnerMustCloseWhatItOpened() {
        var lease = ConnectionLease<Int>()
        lease.claim(1)

        XCTAssertEqual(lease.checkpoint(1, isCurrent: false),
                       .aborted(shutdownTransport: true))
        // The first abort released ownership, so a second checkpoint is a no-op.
        XCTAssertEqual(lease.checkpoint(1, isCurrent: false),
                       .aborted(shutdownTransport: false))
    }
}
