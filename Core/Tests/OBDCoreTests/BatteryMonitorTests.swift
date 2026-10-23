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
        // A charging verdict needs a settled window: ten seconds without the bus
        // reaching 13.5 V is what makes a low reading meaningful.
        feed(m, [
            (0, 12.3, 0),
            (500, 10.0, 150),
            (1200, 12.4, 650),
            (3000, 12.3, 700),
            (5000, 12.4, 700),
            (9000, 12.4, 700),
            (13000, 12.3, 700),
            (16000, 12.4, 700)
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

/// P1: monitoring that begins with the engine already running is not a battery
/// test, and must not produce a verdict.
final class BatteryMonitorStartTests: XCTestCase {

    func testAlreadyRunningProducesNoVerdict() {
        let monitor = BatteryMonitor()
        for (ms, volts) in [(0, 14.1), (1000, 14.2), (2000, 14.1)] {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: 700))
        }
        let report = monitor.report()
        XCTAssertEqual(report.phaseReached, .running)
        XCTAssertFalse(report.startObserved)
        XCTAssertEqual(report.verdict, .insufficientData)
        XCTAssertNil(report.crankMinimumVolts)
        // Charging is still reported, it just cannot clear the battery.
        XCTAssertEqual(report.runningVolts, 14.1)
    }

    func testCompleteStartStillGrades() {
        let monitor = BatteryMonitor()
        for (ms, volts, rpm) in [(0, 12.4, 0.0), (500, 10.1, 180.0), (1500, 14.1, 700.0), (3000, 14.2, 700.0)] {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: rpm))
        }
        let report = monitor.report()
        XCTAssertTrue(report.startObserved)
        XCTAssertEqual(report.verdict, .ok)
    }

    func testVoltageOnlyCrankFallbackStillCounts() {
        let monitor = BatteryMonitor()
        for (ms, volts) in [(0, 12.4), (500, 9.8), (1400, 14.1), (3000, 14.2)] {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: nil))
        }
        let report = monitor.report()
        XCTAssertTrue(report.startObserved)
        XCTAssertEqual(report.verdict, .ok)
    }
}

final class BatteryReportDetailsTests: XCTestCase {

    func testEventDetailsCarryTheUsefulNumbers() {
        let monitor = BatteryMonitor()
        for (ms, volts, rpm) in [(0, 12.4, 0.0), (500, 9.9, 150.0), (1500, 14.1, 700.0), (3000, 14.2, 700.0)] {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: rpm))
        }
        let details = monitor.report().eventDetails

        XCTAssertEqual(details["startObserved"], "true")
        XCTAssertEqual(details["verdict"], "ok")
        XCTAssertEqual(details["crankMinimumVolts"], "9.90")
        // The first second after the engine catches is the alternator spinning
        // up, so it is excluded; 14.2 is the only settled reading here.
        XCTAssertEqual(details["runningVolts"], "14.20")
        XCTAssertEqual(details["finding.crank_minimum"], "ok")
    }

    func testIncompleteStartIsMarkedInDetails() {
        let monitor = BatteryMonitor()
        for (ms, volts) in [(0, 14.1), (1000, 14.2)] {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: 700))
        }
        let details = monitor.report().eventDetails
        XCTAssertEqual(details["startObserved"], "false")
        XCTAssertEqual(details["verdict"], "insufficientData")
        XCTAssertNil(details["crankMinimumVolts"])
    }
}

/// Sequence captured from the car on 2026-10-23: ignition on, crank, recovery.
final class BatteryMonitorRealSequenceTests: XCTestCase {

    private let captured: [(Int, Double, Double?)] = [
        (1_000, 12.20, 0),
        (4_000, 12.20, 0),
        (5_000, 10.90, 0),      // dip — above the absolute 10.6 V floor
        (6_000, 11.71, 671),    // engine caught
        (7_000, 13.01, 670),
        (12_000, 14.14, 665),
        (20_000, 14.19, 660),
        (30_000, 14.22, 660)
    ]

    private func monitor() -> BatteryMonitor {
        let monitor = BatteryMonitor()
        for (ms, volts, rpm) in captured {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: rpm))
        }
        return monitor
    }

    /// The first version missed this start entirely: the dip never went below
    /// 10.6 V and the RPM sample landed after the engine had already caught.
    func testRelativeDipDetectsTheCrank() {
        let report = monitor().report()
        XCTAssertTrue(report.startObserved)
        XCTAssertEqual(report.phaseReached, .running)
        XCTAssertEqual(try! XCTUnwrap(report.crankMinimumVolts), 10.9, accuracy: 0.001)
    }

    /// Charging voltage must come from settled samples, not the recovery ramp.
    func testChargingVoltageIgnoresRecoveryRamp() {
        let report = monitor().report()
        XCTAssertEqual(try! XCTUnwrap(report.runningVolts), 14.19, accuracy: 0.05)
        XCTAssertGreaterThan(report.runningVolts ?? 0, 14.0,
                             "reporting 12.8 V during recovery would look like a failed alternator")
    }

    func testChargingSettlesOnceRecovered() {
        XCTAssertTrue(monitor().chargingSettled)
    }

    func testVerdictIsHealthyForThisStart() {
        XCTAssertEqual(monitor().report().verdict, .ok)
    }
}

/// Session captured on 2026-10-23 04:46: engine ran for eight seconds, then was
/// switched off while the app kept recording.
final class BatteryMonitorShutdownTests: XCTestCase {

    private let captured: [(Int, Double, Double?)] = [
        (0, 12.40, 0),
        (1_000, 10.38, 0),
        (2_000, 12.24, 0),
        (4_000, 12.28, 0),
        (6_000, 13.21, 636),
        (8_000, 14.27, 653),
        (9_000, 12.81, 108),
        (11_000, 12.70, 0),
        (15_000, 12.69, 0),
        (20_000, 12.69, 0)
    ]

    private func report() -> BatteryReport {
        let monitor = BatteryMonitor()
        for (ms, volts, rpm) in captured {
            monitor.ingest(VoltageSample(atMs: ms, volts: volts, rpm: rpm))
        }
        return monitor.report()
    }

    /// Post-shutdown voltage must not be graded as an alternator fault.
    func testChargingVoltageIsTakenWhileTheEngineRan() {
        let report = report()
        XCTAssertEqual(try! XCTUnwrap(report.runningVolts), 14.27, accuracy: 0.05)
        XCTAssertGreaterThan(report.runningVolts ?? 0, 13.5)
    }

    func testNoLowChargingFindingAfterShutdown() {
        let findings = report().findings
        XCTAssertNil(findings.first { $0.key == "running_voltage" && $0.severity != .ok })
    }

    func testCrankStillDetected() {
        let report = report()
        XCTAssertTrue(report.startObserved)
        XCTAssertEqual(try! XCTUnwrap(report.crankMinimumVolts), 10.38, accuracy: 0.001)
    }
}

/// Captured 2026-10-23: alternator reached 13.5 V after 4.3 s, then settled at
/// 12.60 V — battery current sensor concluding the battery is full.
final class BatteryMonitorSmartChargingTests: XCTestCase {

    func testSettlingAfterChargingIsNotAFault() {
        let monitor = BatteryMonitor()
        let samples: [(Int, Double, Double?)] = [
            (0, 12.04, 0), (1_000, 10.6, 180), (2_000, 13.9, 700),
            (5_000, 14.2, 650), (9_000, 13.2, 650), (12_000, 12.6, 650),
            (20_000, 12.6, 650), (30_000, 12.6, 650)
        ]
        for (ms, v, rpm) in samples {
            monitor.ingest(VoltageSample(atMs: ms, volts: v, rpm: rpm))
        }
        let report = monitor.report()
        let charging = report.findings.first { $0.key == "running_voltage" }
        XCTAssertEqual(charging?.severity, .ok, "a system that charged then floated is not faulty")
        XCTAssertTrue(charging?.message.contains("smart charging") == true)
    }

    /// Never reaching 13.5 V is still a fault.
    func testNeverChargingIsStillFlagged() {
        let monitor = BatteryMonitor()
        let samples: [(Int, Double, Double?)] = [
            (0, 12.2, 0), (1_000, 10.4, 180), (3_000, 12.3, 650),
            (15_000, 12.35, 650), (25_000, 12.3, 650)
        ]
        for (ms, v, rpm) in samples {
            monitor.ingest(VoltageSample(atMs: ms, volts: v, rpm: rpm))
        }
        XCTAssertEqual(monitor.report().findings.first { $0.key == "running_voltage" }?.severity, .watch)
    }
}
