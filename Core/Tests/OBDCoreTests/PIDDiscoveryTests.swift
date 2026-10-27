import XCTest
@testable import OBDCore

final class PIDDiscoveryTests: XCTestCase {

    /// The real failure from 27 Oct 2026: the ECU woke part-way through the
    /// connect probe, so only the `0x40` bitmap parsed. Nothing may be filtered
    /// on that evidence — the car advertises 28 PIDs and the session recorded one.
    func testOnlyAHigherBitmapAnsweringFiltersNothing() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x40, pids: [0x42, 0x45, 0x49, 0x4A, 0x4C, 0x4D, 0x4E])

        XCTAssertFalse(discovery.isRooted)
        XCTAssertNil(discovery.lastContiguousBase)
        XCTAssertTrue(discovery.needsRetry)
        for pid in GenericSignals.defaults.compactMap(\.pidValue) {
            XCTAssertTrue(discovery.shouldPoll(pid),
                          "PID \(pid) was dropped on a pass that never read the first bitmap")
        }
    }

    /// The same pass applied to the shipped profile's own signal list: the car
    /// had ten standard parameters that drive, not one.
    func testPartialPassKeepsEveryProfileSignal() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OBDCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("profiles/mitsubishi/outlander-2016-4n14.json")
        let profile = try VehicleProfileLoader.load(from: url)

        var discovery = PIDDiscovery()
        discovery.record(base: 0x40, pids: [0x42, 0x45, 0x49, 0x4A, 0x4C, 0x4D, 0x4E])

        let kept = profile.signals.filter { signal in
            guard let pid = signal.pidValue else { return false }
            return discovery.shouldPoll(pid)
        }
        XCTAssertEqual(profile.signals.count, 10)
        XCTAssertEqual(kept.count, profile.signals.count)
    }

    /// `0x00` answered and declared `0x20`, which then never replied. The range
    /// above `0x20` is unknown, so rpm and voltage must survive the filter.
    func testAGapLeavesTheHigherRangesUnknown() throws {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x05, 0x0C, 0x0D, 0x20])

        XCTAssertEqual(discovery.lastContiguousBase, 0x00)
        XCTAssertEqual(discovery.unansweredBases, [0x20])
        XCTAssertFalse(discovery.chainEnded)
        XCTAssertTrue(discovery.needsRetry)

        XCTAssertTrue(discovery.shouldPoll(0x42), "voltage is above the gap and unknown")
        XCTAssertTrue(discovery.shouldPoll(0x0C), "rpm is inside the answered bitmap")
        XCTAssertFalse(discovery.shouldPoll(0x11), "0x11 was not advertised by the answered bitmap")
        XCTAssertFalse(discovery.shouldPoll(0x02), "0x02 was not advertised by the answered bitmap")
    }

    /// Every declared bitmap answered. The set is authoritative, so a PID the
    /// car does not advertise is dropped even inside a covered range.
    func testCompletePassIsAuthoritative() throws {
        var discovery = PIDDiscovery()
        let first = try XCTUnwrap(PIDCapabilities.supported(fromHex: "4100983B8013", base: 0x00))
        discovery.record(base: 0x00, pids: first)
        discovery.record(base: 0x20, pids: [0x21, 0x23, 0x2C, 0x2D, 0x30, 0x31, 0x33, 0x3C, 0x40])
        discovery.record(base: 0x40, pids: [0x42, 0x45, 0x49, 0x4A, 0x4C, 0x4D, 0x4E])

        XCTAssertTrue(discovery.isRooted)
        XCTAssertTrue(discovery.chainEnded)
        XCTAssertFalse(discovery.needsRetry)
        XCTAssertTrue(discovery.unansweredBases.isEmpty)

        XCTAssertTrue(discovery.shouldPoll(0x0C))
        XCTAssertTrue(discovery.shouldPoll(0x42))
        XCTAssertFalse(discovery.shouldPoll(0x02), "the answered bitmap withheld 0x02")
        XCTAssertFalse(discovery.shouldPoll(0x2F), "the answered bitmap withheld 0x2F")
    }

    /// A bitmap that answered without declaring a successor ends the chain:
    /// nothing above it is supported, so higher PIDs are dropped rather than
    /// polled forever.
    func testChainEndingMakesHigherPIDsUnsupported() throws {
        var discovery = PIDDiscovery()
        let first = try XCTUnwrap(PIDCapabilities.supported(fromHex: "4100983B8013", base: 0x00))
        // A car that stops at 0x20: the first bitmap advertises it, and the
        // second one advertises no successor.
        discovery.record(base: 0x00, pids: first)
        discovery.record(base: 0x20, pids: [0x21, 0x30])

        XCTAssertTrue(discovery.chainEnded)
        XCTAssertFalse(discovery.shouldPoll(0x42))
        XCTAssertTrue(discovery.shouldPoll(0x21))
    }

    func testBaseMapping() {
        XCTAssertEqual(PIDDiscovery.base(for: 0x01), 0x00)
        XCTAssertEqual(PIDDiscovery.base(for: 0x0C), 0x00)
        XCTAssertEqual(PIDDiscovery.base(for: 0x20), 0x00)
        XCTAssertEqual(PIDDiscovery.base(for: 0x21), 0x20)
        XCTAssertEqual(PIDDiscovery.base(for: 0x40), 0x20)
        XCTAssertEqual(PIDDiscovery.base(for: 0x42), 0x40)
        XCTAssertEqual(PIDDiscovery.base(for: 0x60), 0x40)
    }
}
