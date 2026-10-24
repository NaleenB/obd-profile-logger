import Foundation

/// Append-only NDJSON writer for one session.
///
/// Design notes:
/// - One `JSONEncoder` pass per record, then one `write`, so a crash can only
///   ever lose the final partial line.
/// - No buffering layer. An in-memory buffer would increase loss, not reduce it,
///   because this app can be terminated at any moment.
/// - Every failure is thrown. A recorder that silently drops writes is worse
///   than no recorder, because the gap is invisible later.
public final class SessionRecorder {

    public let sessionID: String
    public let directory: URL
    public private(set) var manifest: SessionManifest

    private let clock: MonotonicClock
    private let sampleHandle: FileHandle
    private let eventHandle: FileHandle
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private var closed = false
    private var sampleCount = 0
    private var eventCount = 0

    public static func samplesFilename() -> String { "samples.ndjson" }
    public static func eventsFilename() -> String { "events.ndjson" }
    public static func manifestFilename() -> String { "manifest.json" }
    public static func profileFilename() -> String { "profile.json" }

    public init(
        directory: URL,
        manifest: SessionManifest,
        profileData: Data? = nil,
        clock: MonotonicClock = UptimeClock()
    ) throws {
        self.directory = directory
        self.manifest = manifest
        self.sessionID = manifest.sessionID
        self.clock = clock

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let samplesURL = directory.appendingPathComponent(Self.samplesFilename())
        let eventsURL = directory.appendingPathComponent(Self.eventsFilename())
        let manifestURL = directory.appendingPathComponent(Self.manifestFilename())

        guard FileManager.default.createFile(atPath: samplesURL.path, contents: nil) else {
            throw RecorderError.cannotCreate(samplesURL.lastPathComponent)
        }
        guard FileManager.default.createFile(atPath: eventsURL.path, contents: nil) else {
            throw RecorderError.cannotCreate(eventsURL.lastPathComponent)
        }

        sampleHandle = try FileHandle(forWritingTo: samplesURL)
        eventHandle = try FileHandle(forWritingTo: eventsURL)

        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try manifestEncoder.encode(manifest).write(to: manifestURL)

        // The profile is the decoding key. Store it beside the data so the
        // session remains interpretable even after the app ships a new one.
        if let profileData {
            try profileData.write(to: directory.appendingPathComponent(Self.profileFilename()))
        }
    }

    // MARK: - Samples

    /// Records one successful observation. Never call this for a failed read:
    /// absence is meaningful and must stay absent.
    public func recordSample(
        pid: UInt8,
        name: String,
        value: Double,
        unit: String,
        raw: String? = nil
    ) throws {
        let record = SampleRecord(
            elapsedMs: clock.nowMs(),
            wallTime: WallClock.iso(),
            pid: pid,
            name: name,
            value: value,
            unit: unit,
            raw: raw
        )
        try append(record, to: sampleHandle)
        lock.lock()
        sampleCount += 1
        lock.unlock()
    }

    /// Manufacturer observation. The elapsed time and wall clock are stamped
    /// here so every record uses the recorder's own monotonic origin.
    public func recordManufacturerSample(_ record: SampleRecord) throws {
        var stamped = record
        stamped.elapsedMs = clock.nowMs()
        stamped.wallTime = WallClock.iso()
        try append(stamped, to: sampleHandle)
        lock.lock()
        sampleCount += 1
        lock.unlock()
    }

    // MARK: - Events

    public func recordEvent(_ type: SessionEventType, details: [String: String] = [:]) throws {
        let record = EventRecord(
            elapsedMs: clock.nowMs(),
            wallTime: WallClock.iso(),
            type: type,
            details: details
        )
        try append(record, to: eventHandle)
        lock.lock()
        eventCount += 1
        lock.unlock()
    }

    // MARK: - Lifecycle

    /// Writes the stop event and closes the handles. Idempotent: calling twice
    /// does not produce a second stop event.
    ///
    /// Reports whether finalisation actually succeeded. Cleanup stays
    /// best-effort, but a partial session is never reported as complete.
    @discardableResult
    public func finish(reason: String) -> FinalizeResult {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return .alreadyClosed
        }
        // Closing starts here, and the flag is set under the same lock that
        // guards writes. A concurrent caller cannot write a sample, or a second
        // stop event, between the check and the close.
        closed = true
        lock.unlock()

        var problems: [String] = []

        do {
            let stop = EventRecord(
                elapsedMs: clock.nowMs(),
                wallTime: WallClock.iso(),
                type: .sessionStopped,
                details: ["reason": reason]
            )
            try appendUnchecked(stop, to: eventHandle)
            lock.lock()
            eventCount += 1
            lock.unlock()
        } catch {
            problems.append("stop event: \(error)")
        }

        lock.lock()
        let samples = sampleCount
        let events = eventCount
        lock.unlock()

        if (try? sampleHandle.synchronize()) == nil { problems.append("samples not flushed") }
        if (try? eventHandle.synchronize()) == nil { problems.append("events not flushed") }
        try? sampleHandle.close()
        try? eventHandle.close()

        // The final manifest must be built and snapshotted under the same lock
        // that guards `updateManifest`, or a concurrent update could write a
        // file without `finishedAt` after this one, or interleave a half-applied
        // change into it. `closed` is already true, so any update that acquires
        // the lock from here on returns without writing.
        lock.lock()
        manifest.finishedAt = WallClock.iso()
        manifest.notes.append("sampleCount=\(samples)")
        manifest.notes.append("eventCount=\(events)")
        let manifestData = try? JSONEncoder.pretty.encode(manifest)
        lock.unlock()

        if let manifestData {
            do {
                try manifestData.write(
                    to: directory.appendingPathComponent(Self.manifestFilename()),
                    options: .atomic)
            } catch {
                problems.append("manifest: \(error)")
            }
        } else {
            problems.append("manifest: could not be encoded")
        }

        return problems.isEmpty ? .completed : .incomplete(problems.joined(separator: "; "))
    }

    /// Mutate the manifest while the session is open, and write it straight away.
    ///
    /// Persisting on every change rather than only at `finish` is deliberate: a
    /// session killed mid-recording used to keep the manifest written at start,
    /// so it still claimed the generic profile while its own `profile.json` and
    /// samples were decoded with the vehicle's. An interrupted session is the
    /// one most worth reading later, so it must not lie about what produced it.
    /// These changes are rare — a profile resolves once, the odometer once — so
    /// the write cost is irrelevant next to a sample stream.
    public func updateManifest(_ change: (inout SessionManifest) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        // Checked before mutating: a closed session has already written its
        // final manifest, and a late change must not touch the in-memory copy
        // the writer used.
        guard !closed else { return }
        change(&manifest)
        // Best effort: a manifest that cannot be written is already reported by
        // `finish`, and losing the recording over it would be worse.
        try? JSONEncoder.pretty
            .encode(manifest)
            .write(to: directory.appendingPathComponent(Self.manifestFilename()),
                   options: .atomic)
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    // MARK: - Internals

    private func append<T: Encodable>(_ record: T, to handle: FileHandle) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecorderError.alreadyClosed }
        try write(record, to: handle)
    }

    /// The stop event is the one record written after `closed` is set, by the
    /// caller that owns finalisation.
    private func appendUnchecked<T: Encodable>(_ record: T, to handle: FileHandle) throws {
        try write(record, to: handle)
    }

    private func write<T: Encodable>(_ record: T, to handle: FileHandle) throws {

        var data = try encoder.encode(record)
        data.append(0x0A)   // newline: exactly one object per line
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw RecorderError.writeFailed(error.localizedDescription)
        }
    }
}

public enum FinalizeResult: Equatable {
    case completed
    case alreadyClosed
    /// The session was closed but something could not be written. The directory
    /// is still usable; it is just not guaranteed complete.
    case incomplete(String)

    public var isComplete: Bool { self == .completed }

    public var problem: String? {
        if case .incomplete(let message) = self { return message }
        return nil
    }
}

public enum RecorderError: Error, CustomStringConvertible, Equatable {
    case cannotCreate(String)
    case alreadyClosed
    case writeFailed(String)

    public var description: String {
        switch self {
        case .cannotCreate(let name): return "Could not create \(name)"
        case .alreadyClosed: return "Session is already closed"
        case .writeFailed(let message): return "Write failed: \(message)"
        }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
