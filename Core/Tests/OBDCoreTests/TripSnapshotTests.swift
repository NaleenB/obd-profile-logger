import XCTest
@testable import OBDCore

final class TripSnapshotTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func parameter(
        _ lid: UInt8,
        _ name: String,
        _ value: Double
    ) -> DecodedParameter {
        DecodedParameter(lid: lid, itemNumber: nil, name: name, unit: nil, value: value)
    }

    func testKeyMatchesTheFreshSnapshotForm() {
        // The start and end snapshots are compared by key, so this form is the
        // contract between them, not a display choice.
        XCTAssertEqual(
            TripSnapshot.key(lid: 0x0A, name: "Target A/F COMP. value1"),
            "0A.target_a/f_comp_value1")
        XCTAssertEqual(
            TripSnapshot.key(lid: 0x11, name: "Soot loading by summation"),
            "11.soot_loading_by_summation")
    }

    /// Engine state is not end-of-session state. The cached block holds the last
    /// sweep's rpm and speed, which is how a parked car was written at 44 km/h.
    func testOnlyDeclaredIdentifiersAreWritten() {
        let speed = parameter(0x01, "Vehicle speed", 44)
        let soot = parameter(0x11, "Soot loading by summation", 2.85)
        let updatedAt = [
            speed.id: now.addingTimeInterval(-65),
            soot.id: now.addingTimeInterval(-12)
        ]

        let snapshot = TripSnapshot.cached(
            lids: [0x03, 0x10, 0x11, 0x12],
            parameters: [speed, soot],
            updatedAt: updatedAt,
            now: now
        )

        XCTAssertEqual(snapshot.details, ["11.soot_loading_by_summation": "2.85"])
        XCTAssertNil(
            snapshot.details["01.vehicle_speed"],
            "a stale sweep value must not describe the end state")
    }

    /// The age travels with the values, because the identifiers left in the
    /// snapshot are cached too: the sweep reads them once per pass.
    func testAgeCoversOnlyTheValuesThatWereWritten() {
        let speed = parameter(0x01, "Vehicle speed", 44)
        let soot = parameter(0x11, "Soot loading by summation", 2.85)
        let regens = parameter(0x12, "Count of regeneration", 123)
        let updatedAt = [
            speed.id: now.addingTimeInterval(-65),
            soot.id: now.addingTimeInterval(-30),
            regens.id: now.addingTimeInterval(-95)
        ]

        let snapshot = TripSnapshot.cached(
            lids: [0x11, 0x12],
            parameters: [speed, soot, regens],
            updatedAt: updatedAt,
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.maxAgeSeconds), 95, accuracy: 0.001)
    }

    func testNothingCachedForTheSnapshotIdentifiersWritesNothing() {
        let speed = parameter(0x01, "Vehicle speed", 44)

        let snapshot = TripSnapshot.cached(
            lids: [0x11],
            parameters: [speed],
            updatedAt: [speed.id: now],
            now: now
        )

        XCTAssertTrue(snapshot.details.isEmpty)
        XCTAssertNil(snapshot.maxAgeSeconds)
    }
}
