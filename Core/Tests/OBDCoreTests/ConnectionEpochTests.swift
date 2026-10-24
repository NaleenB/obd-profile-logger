import XCTest
@testable import OBDCore

final class ConnectionEpochTests: XCTestCase {

    func testInitialTokenIsValid() {
        let epoch = ConnectionEpoch()
        XCTAssertTrue(epoch.isValid(epoch.currentToken))
    }

    func testAdvancingInvalidatesEveryEarlierToken() {
        var epoch = ConnectionEpoch()
        let first = epoch.advance()
        XCTAssertTrue(epoch.isValid(first))

        let second = epoch.advance()
        XCTAssertFalse(epoch.isValid(first))
        XCTAssertTrue(epoch.isValid(second))
    }

    func testTokenFromAnotherEpochIsNeverValid() {
        var first = ConnectionEpoch()
        var second = ConnectionEpoch()
        let token = first.advance()
        _ = second.advance()
        XCTAssertFalse(second.isValid(token))
    }
}
