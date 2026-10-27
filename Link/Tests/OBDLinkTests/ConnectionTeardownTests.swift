import XCTest
@testable import OBDLink

final class ConnectionTeardownTests: XCTestCase {

    /// Reconnecting to the same adapter reuses its UUID. The first teardown
    /// must stay pending until its callback, and one callback must release it.
    func testSameIdentifierStaysPendingUntilTheCallback() {
        let coordinator = ConnectionTeardownCoordinator()
        let id = UUID()

        coordinator.begin(id)
        XCTAssertTrue(coordinator.isPending(id))

        // A second request for the same identifier must not need a second
        // callback before a replacement can proceed.
        coordinator.begin(id)
        XCTAssertEqual(coordinator.pendingCount, 1)

        XCTAssertTrue(coordinator.finish(id))
        XCTAssertFalse(coordinator.isPending(id))
        XCTAssertFalse(coordinator.finish(id), "a duplicate callback is not a second teardown")
    }

    func testDifferentIdentifiersDoNotReleaseEachOther() {
        let coordinator = ConnectionTeardownCoordinator()
        let first = UUID()
        let second = UUID()

        coordinator.begin(first)
        coordinator.begin(second)
        XCTAssertTrue(coordinator.finish(first))
        XCTAssertTrue(coordinator.isPending(second))
        XCTAssertFalse(coordinator.isPending(first))
    }

    /// A replacement must actually wait for the old link's callback, not merely
    /// observe that a teardown was requested.
    func testWaitReturnsWhenTheCallbackArrives() async throws {
        let coordinator = ConnectionTeardownCoordinator()
        let id = UUID()
        coordinator.begin(id)

        let waiting = Task {
            try await coordinator.wait(for: id, timeout: 1)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        coordinator.finish(id)

        try await waiting.value
    }

    /// A callback that never arrives must fail the new attempt rather than let
    /// it race the old callback onto the same peripheral.
    func testWaitTimesOutWithoutACallback() async {
        let coordinator = ConnectionTeardownCoordinator()
        let id = UUID()
        coordinator.begin(id)

        do {
            try await coordinator.wait(for: id, timeout: 0.01)
            XCTFail("a missing teardown callback must not permit a replacement")
        } catch {
            XCTAssertTrue(coordinator.isPending(id),
                          "the barrier remains until CoreBluetooth reports the close")
        }
    }
}
