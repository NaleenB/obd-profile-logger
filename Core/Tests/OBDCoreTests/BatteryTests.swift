import XCTest
@testable import OBDCore

final class BatteryTests: XCTestCase {

    private func set(volts: Double) -> ReadingSet {
        var s = ReadingSet()
        s.set(PID.moduleVoltage, volts, unit: "V")
        return s
    }

    // P1: ignition-on voltage must never be reported as a resting measurement.

    func testIgnitionOnIsNotADiagnosis() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 11.5), powerState: .ignitionOn)
        let finding = try? XCTUnwrap(f.first)
        XCTAssertEqual(finding?.key, "voltage_ignition_on")
        XCTAssertNotEqual(finding?.key, "battery_resting")
        XCTAssertNotEqual(finding?.severity, .suspect)
    }

    func testIgnitionOnLowVoltageSaysWhyItIsNotConclusive() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 11.5), powerState: .ignitionOn)
        let message = try? XCTUnwrap(f.first?.message)
        XCTAssertTrue(message?.contains("not a resting measurement") == true)
        XCTAssertEqual(f.first?.severity, .watch)
    }

    func testHealthyIgnitionOnVoltageIsOk() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 12.4), powerState: .ignitionOn)
        XCTAssertEqual(f.first?.severity, .ok)
    }

    func testRecentlyStoppedIsNotSettled() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 11.5), powerState: .resting(settledMinutes: 5))
        XCTAssertEqual(f.first?.key, "voltage_ignition_on")
        XCTAssertEqual(f.first?.severity, .watch)
    }

    func testSettledRestingVoltageCanDiagnose() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 11.7), powerState: .resting(settledMinutes: 120))
        XCTAssertEqual(f.first?.key, "battery_resting")
        XCTAssertEqual(f.first?.severity, .suspect)
    }

    func testSettledHealthyBattery() {
        let f = HealthEvaluator.evaluateBattery(set(volts: 12.5), powerState: .resting(settledMinutes: 120))
        XCTAssertEqual(f.first?.key, "battery_resting")
        XCTAssertEqual(f.first?.severity, .ok)
    }

    func testRunningDefersToChargingCheck() {
        XCTAssertTrue(HealthEvaluator.evaluateBattery(set(volts: 14.2), powerState: .running).isEmpty)
    }

    // P2: staleness must be able to suppress a check.

    func testStaleValueIsIgnored() {
        var s = ReadingSet(referenceMs: 60_000)
        s.set(PID.moduleVoltage, 11.5, unit: "V", atMs: 1_000)
        XCTAssertNil(s.fresh(PID.moduleVoltage, maxAgeMs: 5_000))
        XCTAssertTrue(HealthEvaluator.evaluateBattery(s, powerState: .ignitionOn).isEmpty)
    }

    func testFreshValueIsUsed() {
        var s = ReadingSet(referenceMs: 60_000)
        s.set(PID.moduleVoltage, 11.5, unit: "V", atMs: 58_000)
        XCTAssertEqual(s.fresh(PID.moduleVoltage, maxAgeMs: 5_000), 11.5)
        XCTAssertEqual(s.ageMs(PID.moduleVoltage), 2_000)
    }
}
