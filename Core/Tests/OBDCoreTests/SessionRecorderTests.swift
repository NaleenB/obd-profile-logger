import XCTest
@testable import OBDCore

final class SessionRecorderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obdlogger-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ id: String = "20260101-120000-abcd") -> SessionManifest {
        SessionManifest(
            sessionID: id,
            startedAt: WallClock.iso(),
            appVersion: "test",
            vehicleProfileID: "mitsubishi-outlander-2016-4n14",
            adapterName: "Viecar"
        )
    }

    private func lines(_ directory: URL, _ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Creation

    func testCreatesDirectoryAndManifest() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: recorder.directory.path))

        let read = try XCTUnwrap(SessionStore.readManifest(at: recorder.directory))
        XCTAssertEqual(read.sessionID, "20260101-120000-abcd")
        XCTAssertEqual(read.schemaVersion, SessionSchema.version)
        XCTAssertEqual(read.vehicleProfileID, "mitsubishi-outlander-2016-4n14")
    }

    func testRefusesToReuseASessionID() throws {
        _ = try SessionStore.createSession(root: root, manifest: manifest())
        XCTAssertThrowsError(try SessionStore.createSession(root: root, manifest: manifest())) { error in
            XCTAssertEqual(error as? SessionStoreError, .sessionExists("20260101-120000-abcd"))
        }
    }

    // MARK: Samples

    func testSamplesAreOneJSONObjectPerLine() throws {
        let clock = ManualClock()
        let recorder = try SessionStore.createSession(root: root, manifest: manifest(), clock: clock)

        clock.advance(by: 100)
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 650, unit: "rpm", raw: "410C0A28")
        clock.advance(by: 50)
        try recorder.recordSample(pid: 0x05, name: "coolant", value: 45, unit: "°C", raw: "410555")

        let rows = try lines(recorder.directory, SessionRecorder.samplesFilename())
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertFalse(row.contains("\n"))
            let object = try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any]
            XCTAssertNotNil(object, "each line must be a complete JSON object")
            XCTAssertEqual(object?["schemaVersion"] as? Int, SessionSchema.version)
        }
    }

    func testElapsedTimesAreMonotonicAndDistinct() throws {
        let clock = ManualClock()
        let recorder = try SessionStore.createSession(root: root, manifest: manifest(), clock: clock)

        clock.advance(by: 10)
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 650, unit: "rpm")
        clock.advance(by: 10)
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 700, unit: "rpm")
        clock.advance(by: 10)
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 750, unit: "rpm")

        let rows = try lines(recorder.directory, SessionRecorder.samplesFilename())
        let elapsed = try rows.map { row -> Int in
            let object = try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any]
            return try XCTUnwrap(object?["elapsedMs"] as? Int)
        }
        XCTAssertEqual(elapsed, [10, 20, 30])
        XCTAssertEqual(elapsed, elapsed.sorted())
        XCTAssertEqual(Set(elapsed).count, elapsed.count, "each observation keeps its own timestamp")
    }

    /// A failed read must leave no record. Absence is data.
    func testFailedReadsWriteNothing() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 650, unit: "rpm")
        // Deliberately no call for coolant: the read failed.

        let rows = try lines(recorder.directory, SessionRecorder.samplesFilename())
        XCTAssertEqual(rows.count, 1)

        let object = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["pid"] as? String, "0C")
        XCTAssertNil(object?["coolant"])
    }

    func testRawPayloadIsPreservedForReDecoding() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordSample(pid: 0x23, name: "rail", value: 337.2, unit: "bar", raw: "41230D2C")

        let rows = try lines(recorder.directory, SessionRecorder.samplesFilename())
        let object = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["raw"] as? String, "41230D2C")
        XCTAssertEqual(object?["unit"] as? String, "bar")
    }

    // MARK: Events

    func testEventSerialization() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordEvent(.sessionStarted, details: ["profile": "x"])

        let rows = try lines(recorder.directory, SessionRecorder.eventsFilename())
        XCTAssertEqual(rows.count, 1)
        let object = try JSONSerialization.jsonObject(with: Data(rows[0].utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "session_started")
        let details = object?["details"] as? [String: String]
        XCTAssertEqual(details?["profile"], "x")
    }

    func testFinishIsIdempotent() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordEvent(.sessionStarted)

        XCTAssertEqual(recorder.finish(reason: "user"), .completed)
        XCTAssertEqual(recorder.finish(reason: "user"), .alreadyClosed,
                       "second finish must be a no-op")
        XCTAssertTrue(recorder.isClosed)

        let rows = try lines(recorder.directory, SessionRecorder.eventsFilename())
        let types = try rows.map { row -> String in
            let object = try JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any]
            return try XCTUnwrap(object?["type"] as? String)
        }
        XCTAssertEqual(types.filter { $0 == "session_stopped" }.count, 1)
    }

    func testWriteAfterCloseThrows() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        recorder.finish(reason: "done")
        XCTAssertThrowsError(
            try recorder.recordSample(pid: 0x0C, name: "rpm", value: 1, unit: "rpm")
        ) { error in
            XCTAssertEqual(error as? RecorderError, .alreadyClosed)
        }
    }

    func testManifestIsUpdatedOnFinish() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 1, unit: "rpm")
        recorder.finish(reason: "user")

        let read = try XCTUnwrap(SessionStore.readManifest(at: recorder.directory))
        XCTAssertNotNil(read.finishedAt)
        XCTAssertTrue(read.notes.contains { $0.hasPrefix("sampleCount=1") })
    }

    // MARK: Export

    func testExportContainsSessionFilesAndLeavesSourceIntact() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        try recorder.recordSample(pid: 0x0C, name: "rpm", value: 650, unit: "rpm")
        try recorder.recordEvent(.sessionStarted)
        recorder.finish(reason: "user")

        let before = try Data(contentsOf: recorder.directory.appendingPathComponent("samples.ndjson"))
        let archive = try SessionArchive.export(recorder.directory)
        defer { SessionArchive.discard(archive) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(archive.pathExtension, "zip")

        let names = try SessionArchive.entryNames(of: archive)
        XCTAssertTrue(names.contains("manifest.json"))
        XCTAssertTrue(names.contains("samples.ndjson"))
        XCTAssertTrue(names.contains("events.ndjson"))

        let after = try Data(contentsOf: recorder.directory.appendingPathComponent("samples.ndjson"))
        XCTAssertEqual(before, after, "export must not mutate the source session")
    }

    func testExportMissingSessionThrows() {
        let missing = root.appendingPathComponent("does-not-exist")
        XCTAssertThrowsError(try SessionArchive.export(missing))
    }

    func testEmptySessionStillExports() throws {
        let recorder = try SessionStore.createSession(root: root, manifest: manifest())
        recorder.finish(reason: "no data")
        let archive = try SessionArchive.export(recorder.directory)
        defer { SessionArchive.discard(archive) }
        let names = try SessionArchive.entryNames(of: archive)
        XCTAssertTrue(names.contains("samples.ndjson"))
    }

    // MARK: Listing

    func testSessionsAreListedNewestFirst() throws {
        _ = try SessionStore.createSession(root: root, manifest: manifest("20260101-100000-aaaa"))
        _ = try SessionStore.createSession(root: root, manifest: manifest("20260101-110000-bbbb"))
        let ids = SessionStore.sessions(root: root).map(\.lastPathComponent)
        XCTAssertEqual(ids, ["20260101-110000-bbbb", "20260101-100000-aaaa"])
    }
}

final class SessionSummaryTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ id: String, finished: Bool, samples: Int) throws -> SessionRecorder {
        let manifest = SessionManifest(sessionID: id, startedAt: WallClock.iso(), appVersion: "test", adapterName: "Viecar")
        let recorder = try SessionStore.createSession(root: root, manifest: manifest)
        for index in 0..<samples {
            try recorder.recordSample(pid: 0x0C, name: "rpm", value: Double(index), unit: "rpm")
        }
        if finished { recorder.finish(reason: "user") }
        return recorder
    }

    func testSummariesListNewestFirstWithCounts() throws {
        _ = try make("20260101-100000-aaaa", finished: true, samples: 3)
        _ = try make("20260101-110000-bbbb", finished: true, samples: 5)

        let summaries = SessionStore.summaries(root: root)
        XCTAssertEqual(summaries.map(\.id), ["20260101-110000-bbbb", "20260101-100000-aaaa"])
        XCTAssertEqual(summaries[0].sampleCount, 5)
        XCTAssertTrue(summaries[0].finished)
        XCTAssertEqual(summaries[0].adapterName, "Viecar")
    }

    /// A session that never finished is shown as incomplete, not hidden.
    func testUnfinishedSessionIsVisibleAndMarkedIncomplete() throws {
        _ = try make("20260101-120000-cccc", finished: false, samples: 2)
        let summaries = SessionStore.summaries(root: root)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertFalse(summaries[0].finished)
        XCTAssertTrue(summaries[0].durationDescription.contains("incomplete"))
    }

    func testEmptyRootYieldsNothing() {
        XCTAssertTrue(SessionStore.summaries(root: root).isEmpty)
    }
}
