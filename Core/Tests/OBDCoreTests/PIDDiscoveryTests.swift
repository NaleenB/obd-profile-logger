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

    /// A higher bitmap is not evidence unless the chain reaches it. A late
    /// transmission reply must not add PIDs the engine bitmap never declared.
    func testOrphanHigherBitmapCannotExtendTheChain() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x05, 0x0C, 0x0D])
        discovery.record(base: 0x20, pids: [0x21, 0x30])

        XCTAssertTrue(discovery.isRooted)
        XCTAssertEqual(discovery.lastContiguousBase, 0x00)
        XCTAssertTrue(discovery.unansweredBases.isEmpty)
        XCTAssertTrue(discovery.chainEnded)
        XCTAssertEqual(discovery.supportedPIDs, [0x05, 0x0C, 0x0D])
        XCTAssertFalse(discovery.shouldPoll(0x21),
                       "0x00 never declared the 0x20 range")
    }

    /// A car whose 0x60 bitmap declares 0x80 must leave that range unknown.
    /// Treating the end of the old probe list as the end of the car silently
    /// dropped every supported PID above 0x60.
    func testDeclaredSuccessorAboveSixtyIsUnknownUntilItAnswers() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x20])
        discovery.record(base: 0x20, pids: [0x40])
        discovery.record(base: 0x40, pids: [0x60])
        discovery.record(base: 0x60, pids: [0x61, 0x80])

        XCTAssertEqual(discovery.lastContiguousBase, 0x60)
        XCTAssertEqual(discovery.unansweredBases, [0x80])
        XCTAssertFalse(discovery.chainEnded)
        XCTAssertTrue(discovery.shouldPoll(0x81),
                      "an unanswered 0x80 bitmap cannot prove 0x81 is unsupported")
    }

    /// Once 0x80 answers and declares no successor, the chain really has ended
    /// and PIDs above it may be dropped.
    func testChainCanEndAboveSixty() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x20])
        discovery.record(base: 0x20, pids: [0x40])
        discovery.record(base: 0x40, pids: [0x60])
        discovery.record(base: 0x60, pids: [0x80])
        discovery.record(base: 0x80, pids: [0x81])

        XCTAssertEqual(discovery.lastContiguousBase, 0x80)
        XCTAssertTrue(discovery.chainEnded)
        XCTAssertTrue(discovery.shouldPoll(0x81))
        XCTAssertFalse(discovery.shouldPoll(0xC1))
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

    /// The probe order is part of the discovery contract, not app policy.
    func testNextProbeStopsAtARootFailure() {
        var discovery = PIDDiscovery()
        XCTAssertEqual(discovery.nextProbe(), 0x00)

        // A higher reply without the root must not unlock the rest of the
        // probe list or make the pass look authoritative.
        discovery.record(base: 0x40, pids: [0x42])
        XCTAssertEqual(discovery.nextProbe(), 0x00)
    }

    func testNextProbeFollowsOnlyDeclaredRanges() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x05, 0x0C, 0x20])
        XCTAssertEqual(discovery.nextProbe(), 0x20)

        discovery.record(base: 0x20, pids: [0x21, 0x30])
        XCTAssertNil(discovery.nextProbe(),
                     "0x20 did not declare 0x40, so probing it would be invented")
    }

    func testNextProbeSkipsAnsweredBases() {
        var discovery = PIDDiscovery()
        discovery.record(base: 0x00, pids: [0x20])
        discovery.record(base: 0x20, pids: [0x21, 0x40])
        XCTAssertEqual(discovery.nextProbe(), 0x40)
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
