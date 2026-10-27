import XCTest
@testable import OBDCore

final class OBDProtocolTests: XCTestCase {

    func testAutoDetectedCANIsRecognised() {
        XCTAssertTrue(OBDProtocol.isCAN("6"))
        XCTAssertTrue(OBDProtocol.isCAN("A6"))
        XCTAssertTrue(OBDProtocol.isCAN("7"))
        XCTAssertTrue(OBDProtocol.isCAN("A9"))
        XCTAssertTrue(OBDProtocol.isCAN("ISO 15765-4 (CAN 11/500)"))
    }

    func testNonCANProtocolsAreNotGivenCANHeaders() {
        XCTAssertFalse(OBDProtocol.isCAN(nil))
        XCTAssertFalse(OBDProtocol.isCAN(""))
        XCTAssertFalse(OBDProtocol.isCAN("0"))
        XCTAssertFalse(OBDProtocol.isCAN("A0"))
        XCTAssertFalse(OBDProtocol.isCAN("3"))
        XCTAssertFalse(OBDProtocol.isCAN("ISO 9141-2"))
        XCTAssertFalse(OBDProtocol.isCAN("ISO 14230-4 KWP"))
    }

    /// The first characters of a long description are not a protocol number.
    func testDescriptionContainingUnrelatedDigitsIsNotCAN() {
        XCTAssertFalse(OBDProtocol.isCAN("SAE J1850 PWM"))
    }
}
