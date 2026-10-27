import XCTest
@testable import OBDCore

final class VehicleActivityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// A link drop clears displayed readings but preserves the last sample. A
    /// reconnect must be judged from that sample, not from the original
    /// connection time.
    func testPreservedSampleWinsOverOldConnectionOnReconnect() {
        let lastSample = now.addingTimeInterval(-5)
        let connectedAt = now.addingTimeInterval(-900)

        XCTAssertEqual(
            VehicleActivity.silenceReference(
                lastUpdate: nil,
                lastSampleAt: lastSample,
                connectedAt: connectedAt),
            lastSample)
        XCTAssertEqual(
            VehicleActivity.lastAnswer(lastUpdate: nil, lastSampleAt: lastSample),
            lastSample)
    }

    func testFreshUpdateWinsOverThePreservedSample() {
        let update = now.addingTimeInterval(-2)
        let lastSample = now.addingTimeInterval(-30)

        XCTAssertEqual(
            VehicleActivity.silenceReference(
                lastUpdate: update,
                lastSampleAt: lastSample,
                connectedAt: now.addingTimeInterval(-900)),
            update)
    }

    /// A bare wake probe updates the sample time without producing a value for
    /// the dashboard. The stale display timestamp must not keep the loop quiet.
    func testNewerSampleWinsOverAStaleDisplayUpdate() {
        let update = now.addingTimeInterval(-30)
        let lastSample = now.addingTimeInterval(-1)

        XCTAssertEqual(
            VehicleActivity.silenceReference(
                lastUpdate: update,
                lastSampleAt: lastSample,
                connectedAt: now.addingTimeInterval(-900)),
            lastSample)
        XCTAssertEqual(
            VehicleActivity.lastAnswer(lastUpdate: update, lastSampleAt: lastSample),
            lastSample)
    }

    func testConnectionIsTheFallbackBeforeAnyAnswer() {
        XCTAssertEqual(
            VehicleActivity.silenceReference(
                lastUpdate: nil,
                lastSampleAt: nil,
                connectedAt: now),
            now)
        XCTAssertNil(VehicleActivity.silenceReference(
            lastUpdate: nil, lastSampleAt: nil, connectedAt: nil))
    }
}
