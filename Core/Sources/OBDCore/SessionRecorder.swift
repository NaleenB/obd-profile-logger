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

    public init(directory: URL, manifest: SessionManifest, clock: MonotonicClock = UptimeClock()) throws {
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
    @discardableResult
    public func finish(reason: String) -> Bool {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return false
        }
        lock.unlock()

        try? recordEvent(.sessionStopped, details: ["reason": reason])

        lock.lock()
        closed = true
        let samples = sampleCount
        let events = eventCount
        lock.unlock()

        try? sampleHandle.synchronize()
        try? eventHandle.synchronize()
        try? sampleHandle.close()
        try? eventHandle.close()

        manifest.finishedAt = WallClock.iso()
        manifest.notes.append("sampleCount=\(samples)")
        manifest.notes.append("eventCount=\(events)")
        if let data = try? JSONEncoder.pretty.encode(manifest) {
            try? data.write(to: directory.appendingPathComponent(Self.manifestFilename()))
        }
        return true
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

        var data = try encoder.encode(record)
        data.append(0x0A)   // newline: exactly one object per line
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw RecorderError.writeFailed(error.localizedDescription)
        }
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
