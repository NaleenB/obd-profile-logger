import XCTest
@testable import OBDCore

final class SweepPassTests: XCTestCase {

    private let planned: [UInt8] = [0x01, 0x02, 0x03]

    func testCompletePassClosesAfterTheFinalOutcome() {
        var pass = SweepPass(planned: planned)
        var summary: SweepAccountant.Summary?

        for _ in planned {
            guard let step = pass.next() else { return XCTFail("missing step") }
            pass.requestSent(step.lid)
            summary = pass.finished(step.lid, answered: true) ?? summary
        }

        XCTAssertEqual(summary?.cycle, 1)
        XCTAssertEqual(summary?.attempted, planned.count)
        XCTAssertEqual(summary?.answered, planned.count)
        XCTAssertEqual(summary?.missing, [])
    }

    /// Disconnecting after the header is selected but before `21xx` is sent must
    /// not count the identifier as attempted or close the pass early.
    func testIdentifierIsNotAttemptedWhenDisconnectedBeforeItsRequest() {
        var pass = SweepPass(planned: planned)
        guard let first = pass.next() else { return XCTFail("missing step") }
        XCTAssertFalse(first.isCycleEnd)

        // Connection lost while setting ATSH7E0: the request never went out.
        pass.abandon()

        // The next connection resumes with the following identifier.
        guard let second = pass.next() else { return XCTFail("missing step") }
        XCTAssertEqual(second.lid, 0x02)
        pass.requestSent(second.lid)
        _ = pass.finished(second.lid, answered: true)

        guard let third = pass.next() else { return XCTFail("missing step") }
        XCTAssertEqual(third.lid, 0x03)
        pass.requestSent(third.lid)
        let summary = pass.finished(third.lid, answered: true)

        XCTAssertEqual(summary?.attempted, 2)
        XCTAssertEqual(summary?.answered, 2)
        XCTAssertEqual(summary?.missing, [0x01],
                       "0x01 was never requested, so it belongs in missing")
    }

    /// A connection lost while the request is in flight has no terminal
    /// outcome. The pass must stay open rather than report a cycle it did not
    /// finish observing.
    func testCycleDoesNotCloseWithoutATerminalOutcome() {
        var pass = SweepPass(planned: [0x01])
        guard let step = pass.next() else { return XCTFail("missing step") }
        XCTAssertTrue(step.isCycleEnd)

        pass.requestSent(step.lid)    // sent, then the link dies
        pass.abandon()                // no reply and no timeout observed

        // Resuming the pass re-requests it and only a real outcome closes it.
        guard let retry = pass.next() else { return XCTFail("missing step") }
        XCTAssertEqual(retry.lid, 0x01)
        pass.requestSent(retry.lid)
        let summary = pass.finished(retry.lid, answered: false)
        XCTAssertEqual(summary?.cycle, 1)
        XCTAssertEqual(summary?.attempted, 1)
        XCTAssertEqual(summary?.answered, 0)
    }

    func testEmptyProfileProducesNoStep() {
        var pass = SweepPass(planned: [])
        XCTAssertNil(pass.next())
    }
}
