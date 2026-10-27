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

    /// `7E0` is an 11-bit address. On 29-bit CAN the generic profile (whose
    /// documented remedy for a non-11/500 car is `elmProtocol: "0"`) must keep
    /// the functional broadcast rather than sending an invalid header.
    func testElevenBitHeaderIsNotSentOnTwentyNineBitCAN() {
        XCTAssertTrue(OBDProtocol.isCAN29Bit("7"))
        XCTAssertTrue(OBDProtocol.isCAN29Bit("A7"))
        XCTAssertTrue(OBDProtocol.isCAN29Bit("A9"))
        XCTAssertTrue(OBDProtocol.isCAN29Bit("ISO 15765-4 (CAN 29/500)"))
        XCTAssertFalse(OBDProtocol.isCAN29Bit("6"))
        XCTAssertFalse(OBDProtocol.isCAN29Bit("ISO 15765-4 (CAN 11/500)"))
        XCTAssertFalse(OBDProtocol.isCAN29Bit("ISO 14230-4 KWP"))

        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "7E0", protocolIdentifier: "7"),
            "7DF")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "7E0", protocolIdentifier: "A9"),
            "7DF")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "7E0", protocolIdentifier: "A6"),
            "7E0")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "7E0", protocolIdentifier: "3"),
            "7DF")
    }

    /// A profile that names its own engine address is authoritative, and a
    /// profile with no header still gets the CAN 11-bit engine address.
    func testProfileHeaderIsTrustedAndNilFallsBackToBroadcast() {
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "18DB33F1", protocolIdentifier: "7"),
            "18DB33F1")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: nil, protocolIdentifier: "6"),
            "7E0")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: nil, protocolIdentifier: "3"),
            "7DF")
        XCTAssertEqual(
            OBDProtocol.engineHeader(profileHeader: "7E0", protocolIdentifier: nil),
            "7DF")
    }
}
