import Foundation

/// Owns one active recording and the state the UI shows.
///
/// Exists so the app's recording rules are testable without SwiftUI, and so a
/// write failure cannot leave the UI claiming everything is fine. A failed
/// sample write stops the session immediately: continuing would produce a log
/// with invisible holes.
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
    private let lock = NSLock()

    public init() {}

    public var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    // MARK: - Lifecycle

    public func start(
        manifest: SessionManifest,
        root: URL? = nil,
        clock: MonotonicClock = UptimeClock()
    ) throws {
        guard recorder == nil else { return }
        let created = try SessionStore.createSession(root: root, manifest: manifest, clock: clock)
        try created.recordEvent(.sessionStarted, details: [
            "profile": manifest.vehicleProfileID ?? "none"
        ])
        recorder = created
        directory = created.directory
        lastFinalize = nil
        state = .recording(sessionID: created.sessionID)
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
        unit: String,
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
