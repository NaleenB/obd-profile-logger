import XCTest
@testable import OBDCore

final class AmbientProxyTests: XCTestCase {

    /// The case this exists for: the 0.1.24 session started with the engine
    /// idling and filed a heat-soaked 61 °C intake as ambient.
    func testRunningEngineIsNotAmbient() {
        XCTAssertNil(AmbientProxy.value(intakeAirC: 61, rpm: 650))
    }

    func testEngineOffKeepsTheIntakeReading() {
        XCTAssertEqual(AmbientProxy.value(intakeAirC: 24.5, rpm: 0), 24.5)
    }

    /// Just below the threshold the engine has not caught yet, so the intake is
    /// still answering for the air around the car.
    func testCrankingIsStillAmbient() {
        XCTAssertEqual(
            AmbientProxy.value(intakeAirC: 22, rpm: BatteryMonitor.runningRpm - 1), 22)
    }

    /// A failed rpm read is not evidence the engine was off, so the value cannot
    /// be trusted as ambient.
    func testUnansweredEngineSpeedDropsTheReading() {
        XCTAssertNil(AmbientProxy.value(intakeAirC: 22, rpm: nil))
    }

    func testUnansweredIntakeDropsTheReading() {
        XCTAssertNil(AmbientProxy.value(intakeAirC: nil, rpm: 0))
    }
}
