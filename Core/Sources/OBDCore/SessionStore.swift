import Foundation

/// Where sessions live and how they are named.
public enum SessionStore {

    /// Application Support is the right home for user data that is not a
    /// document: it survives app updates, is included in backups, and works
    /// inside the iOS sandbox without extra entitlements.
    public static func rootDirectory() throws -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("OBDLogger", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Sortable and unique: timestamp plus a short random suffix, so two
    /// sessions started in the same second cannot collide.
    public static func makeSessionID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(4))
        return "\(formatter.string(from: now))-\(suffix)"
    }

    /// Creates a new session directory. Fails rather than reusing an existing
    /// directory, so a session can never be overwritten.
    public static func createSession(
        root: URL? = nil,
        manifest: SessionManifest,
        clock: MonotonicClock = UptimeClock()
    ) throws -> SessionRecorder {
        let base = try root ?? rootDirectory()
        let directory = base.appendingPathComponent(manifest.sessionID, isDirectory: true)

        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SessionStoreError.sessionExists(manifest.sessionID)
        }

        return try SessionRecorder(directory: directory, manifest: manifest, clock: clock)
    }

    /// Newest first.
    public static func sessions(root: URL? = nil) -> [URL] {
        guard let base = try? root ?? rootDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Removes one session directory. Idempotent: deleting something already
    /// gone is not an error, so a stale list cannot produce a spurious failure.
    public static func deleteSession(at directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Removes every session except those named. Returns how many were removed.
    /// `excluding` exists so the session currently being recorded is never
    /// deleted out from under the recorder.
    @discardableResult
    public static func deleteAllSessions(
        root: URL? = nil,
        excluding excludedIDs: Set<String> = []
    ) throws -> Int {
        let base = try root ?? rootDirectory()
        var removed = 0
        for directory in sessions(root: base) {
            if excludedIDs.contains(directory.lastPathComponent) { continue }
            try deleteSession(at: directory)
            removed += 1
        }
        return removed
    }

    public static func readManifest(at directory: URL) -> SessionManifest? {
        let url = directory.appendingPathComponent(SessionRecorder.manifestFilename())
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }

    public static func lineCount(at directory: URL, filename: String) -> Int {
        let url = directory.appendingPathComponent(filename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: true).count
    }
}

public enum SessionStoreError: Error, CustomStringConvertible, Equatable {
    case sessionExists(String)

    public var description: String {
        switch self {
        case .sessionExists(let id): return "Session \(id) already exists"
        }
    }
}
