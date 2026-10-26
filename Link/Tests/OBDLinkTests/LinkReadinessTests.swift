import XCTest
@testable import OBDLink

final class LinkReadinessTests: XCTestCase {

    func testPortDiscoveryAloneIsNotAnEstablishedLink() {
        var readiness = LinkReadiness()
        readiness.resolvePort()

        XCTAssertTrue(readiness.didResolvePort)
        XCTAssertFalse(readiness.isEstablished,
                       "notifications have not been subscribed yet")
    }

    /// A disconnect after the serial port was found but before notification
    /// setup finished used to satisfy `port != nil && readyCont == nil` and was
    /// reported as an established link dropping.
    func testDisconnectAfterPortDiscoveryIsNotAnEstablishedLinkLoss() {
        var readiness = LinkReadiness()
        readiness.resolvePort()
        readiness.markEstablished()   // notification subscription succeeds
        XCTAssertTrue(readiness.isEstablished)

        readiness.reset()             // the link drops or setup fails
        XCTAssertFalse(readiness.isEstablished)
    }

    func testSetupFailureCannotBecomeEstablished() {
        var readiness = LinkReadiness()
        readiness.reset()
        readiness.markEstablished()

        XCTAssertFalse(readiness.isEstablished)
    }

    func testNewConnectionStartsWithNoInheritedReadiness() {
        var readiness = LinkReadiness()
        readiness.resolvePort()
        readiness.markEstablished()
        readiness.reset()
        readiness.resolvePort()

        XCTAssertTrue(readiness.didResolvePort)
        XCTAssertFalse(readiness.isEstablished)
    }
}
