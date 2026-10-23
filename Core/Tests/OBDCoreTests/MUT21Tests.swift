import XCTest
@testable import OBDCore

/// Frames captured from the car on 2026-10-23, engine off, ignition on.
final class MUT21Tests: XCTestCase {

    func testSootBlockDecodes() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6111141F34061D"))
        XCTAssertEqual(frame.localIdentifier, 0x11)
        let soot = MUT21.decodeSoot(frame)
        XCTAssertEqual(try XCTUnwrap(soot.accumulation), 2.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(soot.pressure), 0.3, accuracy: 0.001)
    }

    func testRegenerationBlockDecodes() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B00E60000000000"))
        let regen = MUT21.decodeRegeneration(frame)
        XCTAssertEqual(regen.count, 123)
        XCTAssertEqual(regen.mode, .notRequested)
    }

    /// The whole point of the absolute-offset convention: battery voltage must
    /// come out near 12 V, not 0 V.
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

    func testCombinedStatus() throws {
        var frames: [UInt8: MUT21Frame] = [:]
        frames[0x11] = try XCTUnwrap(MUT21Frame(hex: "6111141F34061D"))
        frames[0x12] = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B00E60000000000"))
        let status = MUT21.status(from: frames)
        XCTAssertEqual(status.sootByAccumulation, 2.6)
        XCTAssertEqual(status.regenerationCount, 123)
        XCTAssertEqual(status.regenerationMode, .notRequested)
        XCTAssertEqual(try XCTUnwrap(MUT21.sootFraction(status)), 2.6 / 12.75, accuracy: 0.0001)
    }

    func testRejectsNonService21() {
        XCTAssertNil(MUT21Frame(hex: "410C0A31"))
    }

    func testShortFrameReturnsNilValue() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6111FF"))
        XCTAssertNil(frame.value(at: 4, length: 1))
    }

    func testSootMaxMatchesManualRange() {
        // 8-bit value at 0.05 g/L per bit.
        XCTAssertEqual(Double(255) * MUT21.sootGramsPerLitrePerBit, 12.75, accuracy: 0.0001)
    }

    /// A non-zero mode is not evidence that regeneration was requested. The
    /// enum mapping is unverified, so it must surface as unknown.
    func testUnrecognisedModeIsNotReportedAsRequested() throws {
        // Same frame as the capture but mode byte 6 = 0x03.
        let frame = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B03E60000000000"))
        let regen = MUT21.decodeRegeneration(frame)
        XCTAssertEqual(regen.count, 123)
        XCTAssertEqual(regen.mode, .unknown(raw: 3))
        XCTAssertNotEqual(regen.mode, .notRequested)
    }

    func testRawModeValueRetained() throws {
        let frame = try XCTUnwrap(MUT21Frame(hex: "6112B1E6007B02E60000000000"))
        let regen = MUT21.decodeRegeneration(frame)
        guard case .unknown(let raw)? = regen.mode else {
            return XCTFail("expected unknown mode, got \(String(describing: regen.mode))")
        }
        XCTAssertEqual(raw, 0x02)
    }
}
