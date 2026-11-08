import Foundation

/// One session that was still open when the app next launched.
///
/// iOS does not call `willTerminate` for a normal termination, and a suspended
/// process can be killed without any of the recorder's teardown running. A
/// session left with no `finishedAt` is therefore over, not live: the next launch
/// closes it at the last activity that was actually recorded. The returned date
/// is what the cold-soak calculation should anchor to, because the launch time
/// says nothing about when the engine last ran.
public struct RepairedSession: Equatable, Sendable {
    public let sessionID: String
    public let lastActivity: Date?

    public init(sessionID: String, lastActivity: Date?) {
        self.sessionID = sessionID
        self.lastActivity = lastActivity
    }
}

public extension SessionStore {

    /// Closes every session whose process died before it could finish.
    ///
    /// Best effort: a directory that cannot be read or written is left alone
    /// rather than replaced with invented data. Repairing is idempotent — once
    /// `finishedAt` is written the session is no longer considered.
    ///
    /// The synthetic stop event carries the last recorded wall time, not the
    /// launch time, and is labelled `synthesized`, so a reader can tell it apart
    /// from a stop the app actually observed.
    @discardableResult
    static func repairInterruptedSessions(root: URL? = nil) -> [RepairedSession] {
        guard let base = try? root ?? rootDirectory() else { return [] }
        var repaired: [RepairedSession] = []

        for directory in sessions(root: base) {
            guard var manifest = readManifest(at: directory),
                  manifest.finishedAt == nil
            else { continue }

            let eventLast = lastRecord(at: directory, filename: SessionRecorder.eventsFilename())
            let sampleLast = lastRecord(at: directory, filename: SessionRecorder.samplesFilename())
            // Samples usually outlive the last event; a disconnect or stop event
            // can outlive the last sample. The end is whichever came later.
            let last = later(eventLast, sampleLast)
            let wallTime = last?.wallTime ?? manifest.startedAt
            let elapsed = (last?.elapsedMs ?? 0) + 1

            // A stop event that made it to disk before the process died is
            // already the record of the end; do not append a second one.
            if last?.type != SessionEventType.sessionStopped.rawValue {
                let stop = EventRecord(
                    elapsedMs: elapsed,
                    wallTime: wallTime,
                    type: .sessionStopped,
                    details: ["reason": "app_terminated", "synthesized": "true"])
                do {
                    try append(stop, to: directory)
                } catch {
                    // Without the stop line the manifest would still claim an
                    // open session, which is the thing being repaired. Leave
                    // this one for a later attempt.
                    continue
                }
            }

            manifest.finishedAt = wallTime
            let note = "Session closed at launch: the app was terminated while recording."
            if !manifest.notes.contains(note) { manifest.notes.append(note) }
            manifest.notes.removeAll { $0.hasPrefix("sampleCount=") || $0.hasPrefix("eventCount=") }
            manifest.notes.append("sampleCount=\(lineCount(at: directory, filename: SessionRecorder.samplesFilename()))")
            manifest.notes.append("eventCount=\(lineCount(at: directory, filename: SessionRecorder.eventsFilename()))")

            let manifestURL = directory.appendingPathComponent(SessionRecorder.manifestFilename())
            do {
                try JSONEncoder.pretty.encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                continue
            }

            repaired.append(RepairedSession(
                sessionID: manifest.sessionID,
                lastActivity: parseWallTime(wallTime)))
        }

        return repaired
    }

    private struct LastRecord {
        let wallTime: String
        let elapsedMs: Int
        let type: String?
    }

    /// The last complete NDJSON record, without loading a whole session.
    ///
    /// Reads a tail window and walks backwards, so an interrupted final write
    /// (a partial line) falls back to the previous record instead of hiding the
    /// timestamp altogether.
    private static func lastRecord(at directory: URL, filename: String) -> LastRecord? {
        let url = directory.appendingPathComponent(filename)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }

        let window: UInt64 = 16 * 1024
        let start = end > window ? end - window : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let wallTime = object["wallTime"] as? String,
                  let elapsedMs = (object["elapsedMs"] as? NSNumber)?.intValue
            else { continue }
            return LastRecord(wallTime: wallTime, elapsedMs: elapsedMs, type: object["type"] as? String)
        }
        return nil
    }

    private static func append(_ event: EventRecord, to directory: URL) throws {
        let url = directory.appendingPathComponent(SessionRecorder.eventsFilename())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(event)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func later(_ first: LastRecord?, _ second: LastRecord?) -> LastRecord? {
        guard let first else { return second }
        guard let second else { return first }
        let a = parseWallTime(first.wallTime)
        let b = parseWallTime(second.wallTime)
        if let a, let b, b > a { return second }
        if a == nil, b != nil { return second }
        return first
    }

    private static func parseWallTime(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
