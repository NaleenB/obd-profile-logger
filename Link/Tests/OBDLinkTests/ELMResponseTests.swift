import XCTest
@testable import OBDLink

final class ELMResponseTests: XCTestCase {

    func testNoDataIsNotAHexPayload() {
        let reply = ELMClient.parse(command: "0100", raw: "\rNO DATA\r\r>")
        XCTAssertNil(reply.payloadHex)
        XCTAssertTrue(reply.failed)
    }

    func testMultipleModulesStaySeparate() {
        let reply = ELMClient.parse(
            command: "010C",
            raw: "410C1A28\r410C0000\r\r>")
        XCTAssertEqual(reply.payloadFrames, ["410C1A28", "410C0000"])
        XCTAssertEqual(reply.payloadHex, "410C1A28")
    }

    func testISOTPMultiFrameIsReassembledWithinOneMessage() {
        let reply = ELMClient.parse(
            command: "0902",
            raw: "014\r0: 49 02 01 4A 4D 46\r1: 58 4C 47 46\r\r>")
        XCTAssertEqual(reply.payloadHex, "4902014A4D46584C4746")
    }

    func testTwoMultiFrameMessagesAreNotJoined() {
        let reply = ELMClient.parse(
            command: "0904",
            raw: "013\r0: 49 04 01 31\r1: 38 36 30\r"
                + "013\r0: 49 04 01 32\r1: 30 32 30\r\r>")
        XCTAssertEqual(reply.payloadFrames, ["49040131383630", "49040132303230"])
    }

    func testEchoAndSearchingLinesAreDropped() {
        let reply = ELMClient.parse(
            command: "0100",
            raw: "0100\rSEARCHING...\r4100BE1FA813\r\r>")
        XCTAssertEqual(reply.payloadHex, "4100BE1FA813")
    }

    func testSupplyVoltageIgnoresNonsense() {
        XCTAssertEqual(ELMClient.parse(command: "ATRV", raw: "12.4V\r\r>").supplyVolts, 12.4)
        XCTAssertNil(ELMClient.parse(command: "ATRV", raw: "32V\r\r>").supplyVolts)
    }

    func testOKRequiresAnExactOKLine() {
        XCTAssertTrue(ELMClient.parse(command: "ATE0", raw: "OK\r\r>").isOK)
        XCTAssertFalse(ELMClient.parse(command: "ATE0", raw: "OKAY NOT REALLY\r\r>").isOK)
    }
}
