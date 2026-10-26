import XCTest
@testable import OBDCore

final class SingleAttemptGateTests: XCTestCase {

    func testOnlyOneAttemptMayOwnTheGate() {
        var gate = SingleAttemptGate<Int>()
        XCTAssertTrue(gate.begin(1))
        XCTAssertFalse(gate.begin(2))
        XCTAssertEqual(gate.active, 1)
    }

    func testInterruptReleasesTheGateForAReplacement() {
        var gate = SingleAttemptGate<Int>()
        XCTAssertTrue(gate.begin(1))
        XCTAssertEqual(gate.interrupt(), 1)
        XCTAssertTrue(gate.isIdle)
        XCTAssertTrue(gate.begin(2))
    }

    /// The old task may return after its replacement starts. Its cleanup must
    /// not clear the new owner, which was the reconnect wedge seen on hardware.
    func testStaleAttemptCannotClearItsReplacement() {
        var gate = SingleAttemptGate<Int>()
        XCTAssertTrue(gate.begin(1))
        _ = gate.interrupt()
        XCTAssertTrue(gate.begin(2))

        XCTAssertFalse(gate.finish(1))
        XCTAssertEqual(gate.active, 2)
        XCTAssertTrue(gate.finish(2))
        XCTAssertTrue(gate.isIdle)
    }
}
