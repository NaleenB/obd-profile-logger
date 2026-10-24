import XCTest
@testable import OBDCore

/// Frames captured from the car on 2026-10-23, engine off, ignition on.
final class MUT21Tests: XCTestCase {

    func testBatteryVoltageConfirmsAbsoluteOffsets() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6101A800006841"))
        // item 1: absolute byte 2, factor 0.0732... -> 12.3 V
        let raw = try XCTUnwrap(frame.value(at: 2, length: 1))
        XCTAssertEqual(raw, 168)
        XCTAssertGreaterThan(Double(raw) * 0.0732, 11.5)
        // The data-relative reading would be byte 4 = 0x00, i.e. 0 V.
        XCTAssertEqual(try XCTUnwrap(frame.value(at: 4, length: 2)), 0x0068)
    }

    /// Engine was off, so item 2 (engine revolution) must decode to 0.
    func testEngineRevolutionIsZeroWhenOff() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6101A800006841"))
        XCTAssertEqual(try XCTUnwrap(frame.value(at: 4, length: 1)), 0)
    }

    func testRejectsNonService21() {
        XCTAssertNil(MUT21Frame(hex: "410C0A31"))
    }

    func testShortFrameReturnsNilValue() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6111FF"))
        XCTAssertNil(frame.value(at: 4, length: 1))
    }

}
