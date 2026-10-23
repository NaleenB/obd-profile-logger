import XCTest
@testable import OBDCore

final class GenericSignalTests: XCTestCase {

    func testDefaultsAreSaneAndDecode() throws {
        let rpm = try XCTUnwrap(GenericSignals.defaults.first { $0.pid == "0C" })
        XCTAssertEqual(rpm.decode([0x0A, 0x28]) ?? 0, 650, accuracy: 0.001)

        let coolant = try XCTUnwrap(GenericSignals.defaults.first { $0.pid == "05" })
        XCTAssertEqual(coolant.decode([0x55]) ?? 0, 45, accuracy: 0.001)

        let voltage = try XCTUnwrap(GenericSignals.defaults.first { $0.pid == "42" })
        XCTAssertEqual(voltage.decode([0x37, 0xBA]) ?? 0, 14.266, accuracy: 0.001)
    }

    func testNoDuplicatePIDs() {
        let pids = GenericSignals.defaults.map(\.pid)
        XCTAssertEqual(Set(pids).count, pids.count)
    }

    func testEveryDefaultHasAValidPID() {
        for signal in GenericSignals.defaults {
            XCTAssertNotNil(signal.pidValue, "bad pid \(signal.pid)")
            XCTAssertTrue(signal.bytes == 1 || signal.bytes == 2)
        }
    }
}

final class PIDCapabilitiesTests: XCTestCase {

    /// Real reply captured from the Outlander's engine ECU.
    func testExpandsCapturedBitmap() throws {
        let supported = try XCTUnwrap(PIDCapabilities.supported(fromHex: "4100983B8013", base: 0x00))
        XCTAssertTrue(supported.contains(0x0C))
        XCTAssertTrue(supported.contains(0x05))
        XCTAssertTrue(supported.contains(0x20))
        XCTAssertFalse(supported.contains(0x02))
    }

    func testBaseOffsetIsApplied() throws {
        // Bitmap starting at 0x20: first bit is PID 0x21.
        let supported = try XCTUnwrap(PIDCapabilities.supported(fromHex: "412080010000", base: 0x20))
        XCTAssertTrue(supported.contains(0x21))
        XCTAssertTrue(supported.contains(0x30))
        XCTAssertFalse(supported.contains(0x20))
    }

    func testRejectsNonBitmap() {
        XCTAssertNil(PIDCapabilities.supported(fromHex: "NO DATA", base: 0x00))
        XCTAssertNil(PIDCapabilities.supported(fromHex: "4100", base: 0x00))
        XCTAssertNil(PIDCapabilities.supported(fromHex: "4200BE1FA813", base: 0x00))
    }

    func testEmptyBitmapYieldsNothing() {
        XCTAssertTrue(PIDCapabilities.expand(bitmap: [0, 0, 0, 0], base: 0x00).isEmpty)
    }
}
