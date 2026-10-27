import XCTest
@testable import OBDCore

final class BatteryCycleTests: XCTestCase {

    /// A failed RPM read must stay absent, not inherit the previous cycle's
    /// value. The voltage fallback is what detects a crank in that case.
    func testFailedRpmLeavesTheVoltageOnlyFallback() throws {
        var cycle = BatteryCycle()
        cycle.record(pid: 0x42, value: 10.9)

        let sample = try XCTUnwrap(cycle.voltageSample)
        XCTAssertEqual(sample.volts, 10.9)
        XCTAssertNil(sample.rpm)

        let monitor = BatteryMonitor()
        monitor.ingest(VoltageSample(atMs: 0, volts: 12.4, rpm: nil))
        monitor.ingest(VoltageSample(atMs: 500, volts: sample.volts, rpm: sample.rpm))
        XCTAssertEqual(monitor.currentPhase, .cranking)
    }

    /// A failed voltage read produces no sample at all. Feeding the old voltage
    /// would fabricate a measurement.
    func testFailedVoltageProducesNoSample() {
        var cycle = BatteryCycle()
        cycle.record(pid: 0x0C, value: 700)
        cycle.record(pid: 0x42, value: nil)

        XCTAssertEqual(cycle.rpm, 700)
        XCTAssertNil(cycle.voltageSample)
    }

    func testOnlyBatteryPIDsAreRecorded() {
        var cycle = BatteryCycle()
        cycle.record(pid: 0x0D, value: 50)
        XCTAssertNil(cycle.rpm)
        XCTAssertNil(cycle.volts)
    }
}
