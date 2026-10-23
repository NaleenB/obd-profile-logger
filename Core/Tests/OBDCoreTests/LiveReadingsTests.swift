import XCTest
@testable import OBDCore

final class DTCSnapshotGateTests: XCTestCase {

    func testFirstSignatureIsEmitted() {
        var gate = DTCSnapshotGate()
        XCTAssertTrue(gate.shouldEmit("ECM:none"))
    }

    /// Unchanged results must not spam the log within one session.
    func testRepeatedSignatureIsSuppressed() {
        var gate = DTCSnapshotGate()
        XCTAssertTrue(gate.shouldEmit("ECM:none"))
        XCTAssertFalse(gate.shouldEmit("ECM:none"))
        XCTAssertFalse(gate.shouldEmit("ECM:none"))
    }

    func testChangedSignatureIsEmitted() {
        var gate = DTCSnapshotGate()
        _ = gate.shouldEmit("ECM:none")
        XCTAssertTrue(gate.shouldEmit("ECM:P0301"))
    }

    /// The bug this exists for: a new session with the same codes as the last
    /// session must still record its own first snapshot.
    func testResetAllowsTheSameSignatureAgain() {
        var gate = DTCSnapshotGate()
        XCTAssertTrue(gate.shouldEmit("ECM:none"))

        gate.reset()   // new session

        XCTAssertTrue(gate.shouldEmit("ECM:none"),
                      "an identical scan in a new session must be recorded")
    }
}

final class LiveReadingsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testStandardAndManufacturerValuesAreKept() {
        var readings = LiveReadings()
        readings.setStandard(pid: "0C", value: 650, at: now)
        readings.setManufacturer(
            DecodedParameter(lid: 0x11, itemNumber: 155,
                             name: "Soot loading by summation", unit: "g/L", value: 2.6),
            at: now
        )
        XCTAssertEqual(readings.values["0C"], 650)
        XCTAssertEqual(readings.manufacturer.count, 1)
        XCTAssertEqual(readings.lastUpdate, now)
        XCTAssertFalse(readings.isEmpty)
    }

    /// A disconnect must not leave numbers on screen that look current.
    func testClearRemovesValuesParametersAndTimestamp() {
        var readings = LiveReadings()
        readings.setStandard(pid: "0C", value: 650, at: now)
        readings.setManufacturer(
            DecodedParameter(lid: 0x10, itemNumber: 120,
                             name: "DPF difference pressure sensor", unit: "kPa", value: 0.5),
            at: now
        )

        readings.clear()

        XCTAssertTrue(readings.values.isEmpty)
        XCTAssertTrue(readings.manufacturer.isEmpty)
        XCTAssertNil(readings.lastUpdate, "a retained timestamp makes cleared readings look fresh")
        XCTAssertTrue(readings.isEmpty)
    }

    func testStalenessUsesLastUpdate() {
        var readings = LiveReadings()
        XCTAssertTrue(readings.isStale(now: now, after: 5), "no data is stale by definition")

        readings.setStandard(pid: "0C", value: 650, at: now)
        XCTAssertFalse(readings.isStale(now: now.addingTimeInterval(2), after: 5))
        XCTAssertTrue(readings.isStale(now: now.addingTimeInterval(30), after: 5))
    }
}
