import XCTest
@testable import OBDCore

final class HealthTests: XCTestCase {

    /// Real values captured from the car on 2026-10-23, cold idle.
    private func liveIdle() -> ReadingSet {
        var set = ReadingSet()
        set.set(PID.rpm, 652, unit: "rpm")
        set.set(PID.coolant, 45, unit: "°C")
        set.set(PID.maf, 5.99, unit: "g/s")
        set.set(PID.railPressure, 337, unit: "bar")
        set.set(PID.map, 101, unit: "kPa")
        set.set(PID.barometric, 101, unit: "kPa")
        set.set(PID.moduleVoltage, 14.27, unit: "V")
        set.set(PID.intakeTemp, 41, unit: "°C")
        return set
    }

    func testCapturedIdleDataPasses() {
        let findings = HealthEvaluator.evaluateIdle(liveIdle())
        for finding in findings {
            XCTAssertEqual(finding.severity, .ok, "\(finding.key): \(finding.message)")
        }
        XCTAssertFalse(findings.isEmpty, "expected idle checks to run")
    }

    func testAirFlowConversion() {
        // 5.99 g/s at 652 rpm on four cylinders -> ~275 mg/cyl, inside 200-935.
        let perCyl = VehicleSpec.airFlowMgPerCylinder(gramsPerSecond: 5.99, rpm: 652)
        XCTAssertNotNil(perCyl)
        XCTAssertEqual(perCyl!, 275.6, accuracy: 0.5)
        XCTAssertTrue(VehicleSpec.idleAirFlowMgPerCyl.contains(perCyl!))
    }

    func testAirFlowConversionRejectsZeroRpm() {
        XCTAssertNil(VehicleSpec.airFlowMgPerCylinder(gramsPerSecond: 5.0, rpm: 0))
    }

    func testIdleSpeedBandFollowsCoolant() {
        // Manual items 2 and 56.
        XCTAssertEqual(VehicleSpec.idleSpeedBand(coolantC: 80), 620...680)
        XCTAssertEqual(VehicleSpec.idleSpeedBand(coolantC: 40), 620...680)
        XCTAssertEqual(VehicleSpec.idleSpeedBand(coolantC: 25), 660...720)
        XCTAssertEqual(VehicleSpec.idleSpeedBand(coolantC: 0), 760...820)
        XCTAssertEqual(VehicleSpec.idleSpeedBand(coolantC: -20), 870...930)
    }

    func testLowIdleSpeedIsFlagged() {
        var set = liveIdle()
        set.set(PID.rpm, 480, unit: "rpm")
        let findings = HealthEvaluator.evaluateIdle(set)
        let idle = findings.first { $0.key == "idle_speed" }
        XCTAssertEqual(idle?.severity, .suspect)
        XCTAssertEqual(idle?.source, .serviceManual(item: 2))
    }

    func testHighRailPressureAtIdleIsFlagged() {
        var set = liveIdle()
        set.set(PID.railPressure, 720, unit: "bar")
        let findings = HealthEvaluator.evaluateIdle(set)
        XCTAssertEqual(findings.first { $0.key == "rail_pressure_idle" }?.severity, .suspect)
    }

    func testRailPressureCheckSkippedWhenNotIdling() {
        var set = liveIdle()
        set.set(PID.rpm, 2000, unit: "rpm")
        let findings = HealthEvaluator.evaluateIdle(set)
        XCTAssertNil(findings.first { $0.key == "rail_pressure_idle" })
    }

    func testLowAirFlowIsFlagged() {
        var set = liveIdle()
        set.set(PID.maf, 1.0, unit: "g/s")   // ~46 mg/cyl at idle, far below spec
        let findings = HealthEvaluator.evaluateIdle(set)
        XCTAssertEqual(findings.first { $0.key == "air_flow_idle" }?.severity, .suspect)
    }

    func testColdEngineAfterLongRunIsFlagged() {
        var set = liveIdle()
        set.set(PID.coolant, 52, unit: "°C")
        set.set(PID.runTime, 1500, unit: "s")
        let findings = HealthEvaluator.evaluateRunning(set)
        XCTAssertEqual(findings.first { $0.key == "coolant_warmup" }?.severity, .suspect)
    }

    func testWarmEngineAfterLongRunIsFine() {
        var set = liveIdle()
        set.set(PID.coolant, 88, unit: "°C")
        set.set(PID.runTime, 1500, unit: "s")
        let findings = HealthEvaluator.evaluateRunning(set)
        XCTAssertNil(findings.first { $0.key == "coolant_warmup" })
    }

    func testHeuristicIsLabelledAsSuch() {
        var set = liveIdle()
        set.set(PID.moduleVoltage, 12.1, unit: "V")
        let findings = HealthEvaluator.evaluateRunning(set)
        let charging = findings.first { $0.key == "charging_voltage" }
        XCTAssertEqual(charging?.severity, .watch)
        guard case .heuristic = charging?.source else {
            return XCTFail("charging voltage must not claim a factory source")
        }
    }

    func testWorstSeverityPropagates() {
        var set = liveIdle()
        set.set(PID.rpm, 400, unit: "rpm")
        let findings = HealthEvaluator.evaluate(set, isIdle: true)
        XCTAssertEqual(HealthEvaluator.worst(findings), .suspect)
    }

    func testEmptySetReportsInsufficientData() {
        XCTAssertEqual(HealthEvaluator.worst([]), .insufficientData)
    }
}
