import XCTest
@testable import OBDCore

final class PIDScalingTests: XCTestCase {

    /// Raw 0x0D2C = 3372. PID 0x23 is 10 kPa per bit, so 33 720 kPa = 337.2 bar.
    func testRailPressureConvertsToBar() {
        XCTAssertEqual(PIDScaling.railPressureBar(raw: 0x0D2C), 337.2, accuracy: 0.001)
        XCTAssertEqual(PIDScaling.railPressureBar(a: 0x0D, b: 0x2C), 337.2, accuracy: 0.001)
    }

    func testRailPressureKiloPascals() {
        XCTAssertEqual(PIDScaling.railPressureKPa(raw: 3372), 33_720, accuracy: 0.001)
    }

    func testZeroIsZero() {
        XCTAssertEqual(PIDScaling.railPressureBar(raw: 0), 0)
    }

    /// The previous implementation returned the raw value, understating pressure
    /// by a factor of ten.
    func testNotRawValue() {
        XCTAssertNotEqual(PIDScaling.railPressureBar(raw: 3372), 3372)
    }
}

final class DTCSnapshotTests: XCTestCase {

    private func diagnostics(mil: Bool?, stored: [String]?, complete: Bool) -> VehicleDiagnostics {
        VehicleDiagnostics(modules: [
            ModuleDiagnostics(
                module: "ECM", header: "7E0",
                milOn: mil, reportedDTCs: stored?.count,
                stored: stored,
                pending: complete ? [] : nil,
                permanent: complete ? [] : nil
            )
        ])
    }

    func testIdenticalScansProduceIdenticalSignatures() {
        let a = diagnostics(mil: false, stored: ["P0301"], complete: true)
        let b = diagnostics(mil: false, stored: ["P0301"], complete: true)
        let outcomes = ["ECM.stored": "ok"]
        XCTAssertEqual(
            DTCSnapshot.signature(a, outcomes: outcomes),
            DTCSnapshot.signature(b, outcomes: outcomes)
        )
    }

    func testOutcomeChangeProducesNewSignature() {
        let d = diagnostics(mil: false, stored: [], complete: true)
        let first = DTCSnapshot.signature(d, outcomes: ["ECM.stored": "empty"])
        let second = DTCSnapshot.signature(d, outcomes: ["ECM.stored": "no_reply"])
        XCTAssertNotEqual(first, second, "an outcome change must not be swallowed")
    }

    func testMilChangeProducesNewSignature() {
        let a = diagnostics(mil: false, stored: [], complete: true)
        let b = diagnostics(mil: true, stored: [], complete: true)
        XCTAssertNotEqual(
            DTCSnapshot.signature(a, outcomes: [:]),
            DTCSnapshot.signature(b, outcomes: [:])
        )
    }

    func testCompletenessChangeProducesNewSignature() {
        let a = diagnostics(mil: false, stored: [], complete: true)
        let b = diagnostics(mil: false, stored: [], complete: false)
        XCTAssertNotEqual(
            DTCSnapshot.signature(a, outcomes: [:]),
            DTCSnapshot.signature(b, outcomes: [:])
        )
    }
}

final class SessionDeletionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func make(_ id: String) throws -> URL {
        let manifest = SessionManifest(sessionID: id, startedAt: WallClock.iso(), appVersion: "test")
        let recorder = try SessionStore.createSession(root: root, manifest: manifest)
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 1, unit: "rpm")
        recorder.finish(reason: "user")
        return recorder.directory
    }

    func testDeletesOneSessionAndLeavesTheRest() throws {
        _ = try make("20260101-100000-aaaa")
        let target = try make("20260101-110000-bbbb")

        try SessionStore.deleteSession(at: target)

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(SessionStore.summaries(root: root).map(\.id), ["20260101-100000-aaaa"])
    }

    func testDeletingSomethingAlreadyGoneIsNotAnError() throws {
        let missing = root.appendingPathComponent("never-existed")
        XCTAssertNoThrow(try SessionStore.deleteSession(at: missing))
    }

    func testDeleteAllExceptTheActiveSession() throws {
        _ = try make("20260101-100000-aaaa")
        _ = try make("20260101-110000-bbbb")
        let active = try make("20260101-120000-cccc")

        let removed = try SessionStore.deleteAllSessions(
            root: root,
            excluding: [active.lastPathComponent]
        )

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(SessionStore.summaries(root: root).map(\.id), ["20260101-120000-cccc"])
    }

    func testDeleteAllOnEmptyStoreIsHarmless() throws {
        XCTAssertEqual(try SessionStore.deleteAllSessions(root: root), 0)
    }
}
