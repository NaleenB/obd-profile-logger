import XCTest
@testable import OBDCore

final class RecordingSessionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest() -> SessionManifest {
        SessionManifest(
            sessionID: SessionStore.makeSessionID(),
            startedAt: WallClock.iso(),
            appVersion: "test",
            vehicleProfileID: "mitsubishi-outlander-2016-4n14",
            adapterName: "Viecar"
        )
    }

    private func started() throws -> RecordingSession {
        let session = RecordingSession()
        try session.start(manifest: manifest(), root: root)
        return session
    }

    private func rows(_ url: URL, _ name: String) throws -> [[String: Any]] {
        let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
        return try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testStartBeginsRecordingAndWritesStartEvent() throws {
        let session = try started()
        XCTAssertTrue(session.isRecording)
        guard case .recording = session.state else { return XCTFail("expected recording") }

        let directory = try XCTUnwrap(session.directory)
        let events = try rows(directory, SessionRecorder.eventsFilename())
        XCTAssertEqual(events.first?["type"] as? String, "session_started")
    }

    /// Discovery can fail at connect and succeed once the ECU wakes. The
    /// manifest is first written at start, so the stop path has to correct it.
    func testDiscoveryIsRecordedAsItEndedNotAsItStarted() throws {
        let session = try started()
        let directory = try XCTUnwrap(session.directory)

        session.updateDiscovery(capabilityDiscovery: "succeeded", supportedPIDs: ["0C", "0D"])
        session.appendNote("Capability discovery did not answer at session start and succeeded once the ECU was awake.")
        session.stop(reason: "test")

        let data = try Data(contentsOf: directory.appendingPathComponent(SessionRecorder.manifestFilename()))
        let written = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(written.capabilityDiscovery, "succeeded")
        XCTAssertEqual(written.supportedPIDs, ["0C", "0D"])
        XCTAssertTrue(written.notes.contains { $0.contains("did not answer at session start") })
    }

    /// A profile can resolve while recording: the manifest and the archived
    /// decoding rules both have to end up describing the samples.
    func testProfileCanBeUpdatedAfterResolution() throws {
        let session = try started()
        let directory = try XCTUnwrap(session.directory)

        let copy = Data(#"{"id":"mitsubishi-outlander-2016-4n14"}"#.utf8)
        try session.replaceProfileCopy(with: copy)
        session.updateProfile(id: "mitsubishi-outlander-2016-4n14",
                              hash: "abc123", match: "calibration")
        session.stop(reason: "test")

        let data = try Data(contentsOf: directory.appendingPathComponent(SessionRecorder.manifestFilename()))
        let written = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(written.vehicleProfileID, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(written.profileHash, "abc123")
        XCTAssertEqual(written.profileMatch, "calibration")

        let archived = try String(contentsOf: directory.appendingPathComponent(SessionRecorder.profileFilename()),
                                  encoding: .utf8)
        XCTAssertTrue(archived.contains("mitsubishi-outlander-2016-4n14"))
    }

    /// A session killed mid-recording must not keep the manifest written at
    /// start. That is how an interrupted session ended up claiming the generic
    /// profile while its own `profile.json` was the vehicle's.
    func testManifestChangesReachDiskBeforeTheSessionEnds() throws {
        let session = try started()
        let directory = try XCTUnwrap(session.directory)

        session.updateProfile(id: "generic-iso15765-can", hash: nil, match: "none")
        session.updateProfile(id: "mitsubishi-outlander-2016-4n14", hash: "abc123", match: "calibration")

        // No stop: this is the state a killed process leaves behind.
        let data = try Data(contentsOf: directory.appendingPathComponent(SessionRecorder.manifestFilename()))
        let written = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(written.vehicleProfileID, "mitsubishi-outlander-2016-4n14")
        XCTAssertEqual(written.profileHash, "abc123")
        XCTAssertEqual(written.profileMatch, "calibration")
        XCTAssertNil(written.finishedAt, "an unfinished session must not look finished")
    }

    /// Exactly one start event, even when the caller supplies metadata.
    func testStartWritesExactlyOneStartEvent() throws {
        let session = RecordingSession()
        try session.start(
            manifest: manifest(),
            root: root,
            details: ["polledPIDs": "0C,0D"]
        )

        let directory = try XCTUnwrap(session.directory)
        let events = try rows(directory, SessionRecorder.eventsFilename())
        let starts = events.filter { $0["type"] as? String == "session_started" }
        XCTAssertEqual(starts.count, 1)

        let details = starts[0]["details"] as? [String: String]
        XCTAssertEqual(details?["polledPIDs"], "0C,0D")
        XCTAssertEqual(details?["profile"], "mitsubishi-outlander-2016-4n14")
    }

    func testStandardSampleIsWritten() throws {
        let session = try started()
        XCTAssertTrue(session.sample(pid: 0x0C, name: "RPM", value: 650, unit: "rpm", raw: "410C0A28"))

        let directory = try XCTUnwrap(session.directory)
        let samples = try rows(directory, SessionRecorder.samplesFilename())
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0]["pid"] as? String, "0C")
        XCTAssertEqual(samples[0]["value"] as? Double, 650)
    }

    /// The manufacturer data is the point of this tool, so it must reach disk
    /// with an identity that is not a standard PID.
    func testManufacturerSampleRoundTrips() throws {
        let session = try started()
        XCTAssertTrue(session.manufacturerSample(
            lid: 0x11,
            itemNumber: 155,
            name: "Soot loading by summation",
            value: 2.6,
            unit: "g/L",
            raw: "6111141F34061D"
        ))

        let directory = try XCTUnwrap(session.directory)
        let samples = try rows(directory, SessionRecorder.samplesFilename())
        XCTAssertEqual(samples.count, 1)

        let row = samples[0]
        XCTAssertNil(row["pid"], "manufacturer samples must not be forced into a PID field")
        XCTAssertEqual(row["service"] as? String, "21")
        XCTAssertEqual(row["lid"] as? String, "11")
        XCTAssertEqual(row["itemNumber"] as? Int, 155)
        XCTAssertEqual(row["name"] as? String, "Soot loading by summation")
        XCTAssertEqual(row["unit"] as? String, "g/L")
        XCTAssertEqual(row["value"] as? Double, 2.6)
        XCTAssertEqual(row["schemaVersion"] as? Int, SessionSchema.version)
    }

    /// An unknown unit is omitted rather than written as an empty string.
    func testUnknownUnitIsOmitted() throws {
        let session = try started()
        XCTAssertTrue(session.manufacturerSample(
            lid: 0x47,
            itemNumber: 16,
            name: "EGR valve position",
            value: 12,
            unit: "",
            raw: "6147000C"
        ))

        let directory = try XCTUnwrap(session.directory)
        let samples = try rows(directory, SessionRecorder.samplesFilename())
        XCTAssertNil(samples[0]["unit"])
    }

    func testStopReportsCompletedAndIsIdempotent() throws {
        let session = try started()
        _ = session.sample(pid: 0x05, name: "Coolant", value: 45, unit: "°C")

        XCTAssertEqual(session.stop(reason: "user"), .completed)
        guard case .stopped = session.state else { return XCTFail("expected stopped") }
        XCTAssertEqual(session.stop(reason: "user"), .alreadyClosed)

        let directory = try XCTUnwrap(session.directory)
        let events = try rows(directory, SessionRecorder.eventsFilename())
        XCTAssertEqual(events.filter { $0["type"] as? String == "session_stopped" }.count, 1)
    }

    func testSampleAfterStopIsRejected() throws {
        let session = try started()
        session.stop(reason: "user")
        XCTAssertFalse(session.sample(pid: 0x0C, name: "RPM", value: 1, unit: "rpm"))
    }

    /// A write failure must stop recording and be visible, not silently drop data.
    func testWriteFailureStopsRecordingAndKeepsData() throws {
        let session = try started()
        _ = session.sample(pid: 0x0C, name: "RPM", value: 650, unit: "rpm")
        let directory = try XCTUnwrap(session.directory)

        session.handleWriteFailure(RecorderError.writeFailed("disk full"))

        XCTAssertFalse(session.isRecording)
        guard case .failed(let message) = session.state else {
            return XCTFail("expected failed state, got \(session.state)")
        }
        XCTAssertTrue(message.contains("disk full"))
        XCTAssertEqual(session.directory, directory, "the partial session stays addressable")
        XCTAssertEqual(session.lastFinalize?.isComplete, false)

        // Data written before the failure is still on disk.
        let samples = try rows(directory, SessionRecorder.samplesFilename())
        XCTAssertEqual(samples.count, 1)
    }

    func testIncompleteFinalizeIsNotReportedAsStopped() throws {
        let session = try started()
        session.handleWriteFailure(RecorderError.writeFailed("no space"))
        guard case .failed = session.state else {
            return XCTFail("a partial session must not present as saved")
        }
    }
}

final class SessionEventOrderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("obd-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Events written before the session starts are dropped, so the app must
    /// start recording first. This test pins that behaviour down.
    func testEventBeforeStartIsDiscarded() throws {
        let session = RecordingSession()
        XCTAssertFalse(session.event(.adapterConnected, ["adapter": "Viecar"]))
        XCTAssertEqual(session.state, .idle)
    }

    func testAdapterEventAfterStartIsWritten() throws {
        let session = RecordingSession()
        let manifest = SessionManifest(
            sessionID: SessionStore.makeSessionID(),
            startedAt: WallClock.iso(),
            appVersion: "test"
        )
        try session.start(manifest: manifest, root: root)
        XCTAssertTrue(session.event(.adapterConnected, ["adapter": "Viecar"]))
        session.stop(reason: "user")

        let directory = try XCTUnwrap(session.directory)
        let text = try String(contentsOf: directory.appendingPathComponent("events.ndjson"), encoding: .utf8)
        let types = try text.split(separator: "\n").compactMap { line -> String? in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["type"] as? String
        }
        XCTAssertEqual(types.filter { $0 == "adapter_connected" }.count, 1)
    }

    func testManifestCarriesCapabilityDiscovery() throws {
        let manifest = SessionManifest(
            sessionID: "x",
            startedAt: WallClock.iso(),
            appVersion: "test",
            supportedPIDs: ["05", "0C", "0D"],
            capabilityDiscovery: "succeeded"
        )
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SessionManifest.self, from: data)
        XCTAssertEqual(decoded.supportedPIDs, ["05", "0C", "0D"])
        XCTAssertEqual(decoded.capabilityDiscovery, "succeeded")
    }

    func testFailedDiscoveryIsDistinguishableFromEmptySupport() throws {
        let failed = SessionManifest(sessionID: "x", startedAt: WallClock.iso(),
                                     appVersion: "test", supportedPIDs: nil,
                                     capabilityDiscovery: "failed")
        let empty = SessionManifest(sessionID: "y", startedAt: WallClock.iso(),
                                    appVersion: "test", supportedPIDs: [],
                                    capabilityDiscovery: "succeeded")
        XCTAssertNil(failed.supportedPIDs)
        XCTAssertEqual(empty.supportedPIDs, [])
        XCTAssertNotEqual(failed.capabilityDiscovery, empty.capabilityDiscovery)
    }
}
