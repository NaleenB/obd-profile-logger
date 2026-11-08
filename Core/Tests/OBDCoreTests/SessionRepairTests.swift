import XCTest
@testable import OBDCore

final class SessionRepairTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRepairTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testRepairsAtLastEventAndWritesSynthesizedStop() throws {
        let directory = try makeSession(
            id: "20261108-110830-73E9",
            startedAt: "2026-11-08T01:08:30.344Z",
            events: [
                (1_000, "2026-11-08T01:08:31.344Z", .sessionStarted),
                (4_658_000, "2026-11-08T02:26:08.344Z", .adapterDisconnected)
            ],
            samples: [
                (3_000, "2026-11-08T01:08:33.344Z"),
                (4_100_000, "2026-11-08T02:16:49.344Z")
            ])

        let repaired = SessionStore.repairInterruptedSessions(root: root)

        XCTAssertEqual(repaired.count, 1)
        XCTAssertEqual(repaired[0].sessionID, "20261108-110830-73E9")
        XCTAssertEqual(repaired[0].lastActivity?.timeIntervalSince1970 ?? 0,
                       date("2026-11-08T02:26:08.344Z").timeIntervalSince1970,
                       accuracy: 0.001)

        let manifest = try XCTUnwrap(SessionStore.readManifest(at: directory))
        XCTAssertEqual(manifest.finishedAt, "2026-11-08T02:26:08.344Z")
        XCTAssertTrue(manifest.notes.contains("Session closed at launch: the app was terminated while recording."))
        XCTAssertTrue(manifest.notes.contains("sampleCount=2"))
        XCTAssertTrue(manifest.notes.contains("eventCount=3"))

        let events = try events(at: directory)
        let last = try XCTUnwrap(events.last)
        XCTAssertEqual(last.type, .sessionStopped)
        XCTAssertEqual(last.details["reason"], "app_terminated")
        XCTAssertEqual(last.details["synthesized"], "true")
        XCTAssertEqual(last.wallTime, "2026-11-08T02:26:08.344Z")
        XCTAssertEqual(last.elapsedMs, 4_658_001)
    }

    func testUsesSampleWhenItIsLaterThanTheLastEvent() throws {
        let directory = try makeSession(
            id: "20261108-150611-E285",
            startedAt: "2026-11-08T05:06:11.467Z",
            events: [(1_000, "2026-11-08T05:06:12.467Z", .sessionStarted)],
            samples: [(100_000, "2026-11-08T05:16:51.467Z")])

        let repaired = SessionStore.repairInterruptedSessions(root: root)

        XCTAssertEqual(repaired.count, 1)
        let manifest = try XCTUnwrap(SessionStore.readManifest(at: directory))
        XCTAssertEqual(manifest.finishedAt, "2026-11-08T05:16:51.467Z")
        let last = try XCTUnwrap(try events(at: directory).last)
        XCTAssertEqual(last.elapsedMs, 100_001)
        XCTAssertEqual(last.wallTime, "2026-11-08T05:16:51.467Z")
    }

    func testCleanSessionIsLeftAlone() throws {
        let directory = try makeSession(
            id: "20261108-090000-AAAA",
            startedAt: "2026-11-08T00:00:00.000Z",
            finishedAt: "2026-11-08T00:01:00.000Z",
            events: [(1_000, "2026-11-08T00:00:01.000Z", .sessionStarted)],
            samples: [(2_000, "2026-11-08T00:00:02.000Z")])

        XCTAssertTrue(SessionStore.repairInterruptedSessions(root: root).isEmpty)
        let manifest = try XCTUnwrap(SessionStore.readManifest(at: directory))
        XCTAssertEqual(manifest.finishedAt, "2026-11-08T00:01:00.000Z")
        XCTAssertEqual(try events(at: directory).count, 1)
    }

    func testEmptySessionFallsBackToStartTime() throws {
        let directory = try makeSession(
            id: "20261108-120000-BBBB",
            startedAt: "2026-11-08T02:00:00.000Z",
            events: [],
            samples: [])

        XCTAssertEqual(SessionStore.repairInterruptedSessions(root: root).count, 1)
        let manifest = try XCTUnwrap(SessionStore.readManifest(at: directory))
        XCTAssertEqual(manifest.finishedAt, "2026-11-08T02:00:00.000Z")
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        startedAt: String,
        finishedAt: String? = nil,
        events: [(Int, String, SessionEventType)],
        samples: [(Int, String)]
    ) throws -> URL {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = SessionManifest(
            sessionID: id,
            startedAt: startedAt,
            finishedAt: finishedAt,
            appVersion: "0.1.28")
        try JSONEncoder.pretty
            .encode(manifest)
            .write(to: directory.appendingPathComponent(SessionRecorder.manifestFilename()))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var eventData = Data()
        for (elapsed, wall, type) in events {
            eventData.append(try encoder.encode(EventRecord(
                elapsedMs: elapsed, wallTime: wall, type: type)))
            eventData.append(0x0A)
        }
        try eventData.write(to: directory.appendingPathComponent(SessionRecorder.eventsFilename()))

        var sampleData = Data()
        for (elapsed, wall) in samples {
            let object: [String: Any] = [
                "schemaVersion": 4,
                "elapsedMs": elapsed,
                "wallTime": wall,
                "pid": "0C",
                "name": "Engine speed",
                "value": 0,
                "unit": "rpm",
                "raw": "410C0000"
            ]
            sampleData.append(try JSONSerialization.data(withJSONObject: object))
            sampleData.append(0x0A)
        }
        try sampleData.write(to: directory.appendingPathComponent(SessionRecorder.samplesFilename()))
        return directory
    }

    private func events(at directory: URL) throws -> [EventRecord] {
        let url = directory.appendingPathComponent(SessionRecorder.eventsFilename())
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map {
            try JSONDecoder().decode(EventRecord.self, from: Data($0.utf8))
        }
    }

    private func date(_ string: String) -> Date {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)) ?? Date()
    }
}
