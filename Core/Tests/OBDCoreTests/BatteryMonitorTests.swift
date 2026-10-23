import XCTest
@testable import OBDCore

final class BatteryMonitorTests: XCTestCase {

    private func feed(_ monitor: BatteryMonitor, _ rows: [(Int, Double, Double?)]) {
        for (ms, volts, rpm) in rows {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: rpm))
        }
    }

    /// A normal start: key on, brief dip, engine catches, alternator recovers.
    func testHealthyStart() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.4, 0),
            (400, 12.3, 0),
            (800, 10.2, 180),
            (1100, 9.9, 220),
            (1400, 11.2, 320),
            (1800, 13.9, 700),
            (2500, 14.2, 720),
            (4000, 14.1, 710)
        ])
        let r = m.report()
        XCTAssertEqual(r.phaseReached, .running)
        XCTAssertEqual(r.preCrankVolts, 12.3)
        XCTAssertEqual(try XCTUnwrap(r.crankMinimumVolts), 9.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.runningVolts), 14.1, accuracy: 0.001)
        XCTAssertEqual(r.verdict, .ok)
    }

    /// A battery that sags below 9 V under load is failing.
    func testFailingCrankIsSuspect() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.2, 0),
            (500, 8.5, 120),
            (900, 8.1, 150),
            (1500, 14.0, 650),
            (3000, 14.2, 700)
        ])
        let r = m.report()
        XCTAssertEqual(try XCTUnwrap(r.crankMinimumVolts), 8.1, accuracy: 0.001)
        XCTAssertEqual(r.verdict, .suspect)
    }

    func testMarginalCrankIsWatch() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.2, 0),
            (500, 9.2, 130),
            (1200, 14.0, 650),
            (3000, 14.1, 700)
        ])
        XCTAssertEqual(m.report().verdict, .watch)
    }

    /// Low charging voltage is an alternator finding, not a battery one.
    func testLowChargingVoltageIsFlagged() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.3, 0),
            (500, 10.0, 150),
            (1200, 12.4, 650),
            (3000, 12.3, 700),
            (5000, 12.4, 700)
        ])
        let r = m.report()
        let charging = r.findings.first { $0.key == "running_voltage" }
        XCTAssertEqual(charging?.severity, .watch)
        XCTAssertTrue(charging?.message.contains("not a battery fault") == true)
    }

    /// Engine never started: report insufficient data rather than a verdict.
    func testNoStartReportsInsufficientData() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 11.8, 0),
            (1000, 11.8, 0),
            (2000, 11.9, 0)
        ])
        let r = m.report()
        XCTAssertEqual(r.phaseReached, .ignitionOn)
        XCTAssertEqual(r.verdict, .insufficientData)
    }

    /// Voltage dip alone, with no RPM reported, still counts as a crank.
    func testCrankDetectedByVoltageWhenRpmMissing() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.4, nil),
            (500, 9.8, nil),
            (1200, 14.1, nil),
            (3000, 14.2, nil)
        ])
        let r = m.report()
        XCTAssertEqual(try XCTUnwrap(r.crankMinimumVolts), 9.8, accuracy: 0.001)
        XCTAssertEqual(r.phaseReached, .running)
    }

    /// Once running, a later dip must not be treated as a second crank.
    func testRunningIsLatched() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.4, 0),
            (500, 9.9, 150),
            (1500, 14.1, 700),
            (4000, 13.9, 690),
            (5000, 10.1, nil)   // spurious low read after the engine is up
        ])
        let r = m.report()
        XCTAssertEqual(r.phaseReached, .running)
        XCTAssertEqual(try XCTUnwrap(r.crankMinimumVolts), 9.9, accuracy: 0.001)
    }

    func testRecoveryTimeRecorded() {
        let m = BatteryMonitor()
        feed(m, [
            (0, 12.4, 0),
            (500, 9.9, 150),
            (1400, 12.1, 600),
            (3000, 13.9, 700),
            (4000, 14.1, 700)
        ])
        let r = m.report()
        XCTAssertNotNil(r.recoveryMs)
        XCTAssertGreaterThan(r.recoveryMs ?? 0, 1000)
    }
}
