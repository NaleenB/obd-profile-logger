import Foundation

/// Owns one active recording and the state the UI shows.
///
/// Exists so the app's recording rules are testable without SwiftUI, and so a
/// write failure cannot leave the UI claiming everything is fine. A failed
/// sample write stops the session immediately: continuing would produce a log
/// with invisible holes.
/// Not internally synchronised: the app owns it on the main actor, while
/// `SessionRecorder` underneath is safe for concurrent writes and finalisation.
public final class RecordingSession {

    public enum State: Equatable {
        case idle
        case recording(sessionID: String)
        case stopped(sessionID: String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var directory: URL?
    public private(set) var lastFinalize: FinalizeResult?

    private var recorder: SessionRecorder?

    public init() {}

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Starts a session and writes exactly one `session_started` event.
    /// Callers may add details; they must not emit a second start event.
    public func start(
        manifest: SessionManifest,
        root: URL? = nil,
        clock: MonotonicClock = UptimeClock(),
        details: [String: String] = [:],
        profileData: Data? = nil
    ) throws {
        guard recorder == nil else { return }
        let created = try SessionStore.createSession(
            root: root, manifest: manifest, profileData: profileData, clock: clock)
        var startDetails = details
        startDetails["profile"] = manifest.vehicleProfileID ?? "none"
        try created.recordEvent(.sessionStarted, details: startDetails)
        recorder = created
        directory = created.directory
        lastFinalize = nil
        state = .recording(sessionID: created.sessionID)
    }

    /// Odometer read at the start and at the end of a session.
    ///
    /// The start reading is written as soon as it is obtained, not at close:
    /// with a cold ECU it only answers once the car has been identified and
    /// woken, which can be long after the manifest was first written. Soot per
    /// kilometre and the regeneration interval both need it, and they are
    /// useless with only an end value.
    public func updateOdometer(start: Int? = nil, end: Int? = nil) {
        guard let recorder else { return }
        recorder.updateManifest {
            if let start { $0.odometerStartKm = start }
            if let end { $0.odometerEndKm = end }
        }
    }

    /// Discovery can fail at connect, while the ECU is still asleep, and succeed
    /// once it answers. Record the outcome that held for the session rather than
    /// the state at the moment the manifest was first written.
    public func updateDiscovery(capabilityDiscovery: String, supportedPIDs: [String]?) {
        guard let recorder else { return }
        recorder.updateManifest {
            $0.capabilityDiscovery = capabilityDiscovery
            $0.supportedPIDs = supportedPIDs
        }
    }

    /// Appends a note for something that changed after the session started.
    public func appendNote(_ note: String) {
        guard let recorder else { return }
        recorder.updateManifest { $0.notes.append(note) }
    }

    /// The profile can resolve mid-session when the car was cold at connect.
    /// Record the profile the samples were actually taken with, not the one the
    /// manifest happened to start with.
    public func updateProfile(id: String, hash: String?, match: String) {
        guard let recorder else { return }
        recorder.updateManifest {
            $0.vehicleProfileID = id
            $0.profileHash = hash
            $0.profileMatch = match
        }
    }

    /// Replaces the archived decoding rules. Safe because manufacturer samples
    /// are only written once a profile is resolved, so the copy always describes
    /// every block sample in the session.
    public func replaceProfileCopy(with data: Data) throws {
        guard let recorder else { return }
        try data.write(to: recorder.directory.appendingPathComponent(SessionRecorder.profileFilename()))
    }

    /// Stops recording and returns what actually happened. A partial session is
    /// reported as `.incomplete`, never as saved.
    @discardableResult
    public func stop(reason: String) -> FinalizeResult {
        guard let active = recorder else { return .alreadyClosed }
        let result = active.finish(reason: reason)
        recorder = nil
        directory = active.directory
        lastFinalize = result
        state = result.isComplete
            ? .stopped(sessionID: active.sessionID)
            : .failed("Session saved with problems: \(result.problem ?? "unknown")")
        return result
    }

    // MARK: - Writes

    /// A standard OBD observation. Returns false when the write failed, in which
    /// case the session has been stopped so the UI cannot keep saying "recording".
    @discardableResult
    public func sample(
        pid: UInt8,
        name: String,
        value: Double,
        unit: String,
        raw: String? = nil
    ) -> Bool {
        guard let recorder, isRecording else { return false }
        do {
            try recorder.recordSample(pid: pid, name: name, value: value, unit: unit, raw: raw)
            return true
        } catch {
            handleWriteFailure(error)
            return false
        }
    }

    /// A manufacturer observation from service `0x21`.
    @discardableResult
    public func manufacturerSample(
        service: UInt8 = 0x21,
        lid: UInt8,
        itemNumber: Int?,
        name: String,
        value: Double,
        unit: String?,
        raw: String? = nil
    ) -> Bool {
        guard let recorder, isRecording else { return false }
        do {
            let record = SampleRecord(
                elapsedMs: 0,   // replaced below by the recorder's own clock
                wallTime: WallClock.iso(),
                service: service,
                lid: lid,
                itemNumber: itemNumber,
                name: name,
                value: value,
                unit: unit,
                raw: raw
            )
            try recorder.recordManufacturerSample(record)
            return true
        } catch {
            handleWriteFailure(error)
            return false
        }
    }

    @discardableResult
    public func event(_ type: SessionEventType, _ details: [String: String] = [:]) -> Bool {
        guard let recorder, isRecording else { return false }
        do {
            try recorder.recordEvent(type, details: details)
            return true
        } catch {
            handleWriteFailure(error)
            return false
        }
    }

    /// Central failure path. Exposed internally so the transition can be tested
    /// without having to make a real disk write fail.
    func handleWriteFailure(_ error: Error) {
        let message = "\(error)"
        // Keep the directory: whatever was written is still useful, but mark the
        // session as incomplete rather than pretending it is sound.
        if let active = recorder {
            _ = active.finish(reason: "write_failed")
            directory = active.directory
            lastFinalize = .incomplete(message)
        }
        recorder = nil
        state = .failed("Recording stopped: \(message)")
    }
}
