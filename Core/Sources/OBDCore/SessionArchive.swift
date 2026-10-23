import Foundation

/// Exports a completed session as a ZIP without touching the source directory.
///
/// Uses `NSFileCoordinator`'s `.forUploading` reading mode, which is the
/// platform-provided way to produce a ZIP of a directory. No third-party
/// dependency, and it works on both iOS and macOS.
public enum SessionArchive {

    /// Stable layout inside the archive: `manifest.json`, `samples.ndjson`,
    /// `events.ndjson` at the archive root, plus a top-level folder named after
    /// the session.
    public static func export(_ sessionDirectory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ArchiveError.missingSession(sessionDirectory.lastPathComponent)
        }

        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var produced: URL?
        var copyError: Error?

        coordinator.coordinate(
            readingItemAt: sessionDirectory,
            options: .forUploading,
            error: &coordinationError
        ) { temporaryURL in
            do {
                let filename = "\(sessionDirectory.lastPathComponent)-\(UUID().uuidString.prefix(8)).zip"
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                produced = destination
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            throw ArchiveError.failed(coordinationError.localizedDescription)
        }
        if let copyError {
            throw ArchiveError.failed(copyError.localizedDescription)
        }
        guard let produced else {
            throw ArchiveError.failed("the system produced no archive")
        }
        return produced
    }

    /// One archive containing several sessions, each in its own folder.
    ///
    /// Stages copies first so the sources are only ever read, and so the archive
    /// has a predictable single root rather than a scatter of sibling folders.
    public static func exportAll(
        _ sessionDirectories: [URL],
        containerName: String = "OBDLogger-sessions"
    ) throws -> URL {
        guard !sessionDirectories.isEmpty else {
            throw ArchiveError.failed("there are no sessions to export")
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("obdlogger-staging-\(UUID().uuidString)", isDirectory: true)
        let root = staging.appendingPathComponent(containerName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        for directory in sessionDirectories {
            let destination = root.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try FileManager.default.copyItem(at: directory, to: destination)
        }

        return try export(root)
    }

    /// Removes a previously exported archive. Called when the share sheet has
    /// been dismissed, so temporary files do not accumulate.
    public static func discard(_ url: URL) {
        guard url.pathExtension == "zip",
              url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    #if os(macOS)
    /// Lists archive entries by name. Test helper; macOS only, so the library
    /// still builds for iOS without `Process`.
    public static func entryNames(of archive: URL) throws -> [String] {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw ArchiveError.failed("archive not found")
        }

        // `FileManager.unzipItem` is available on macOS 10.15+/iOS 13+ via
        // Foundation's archive support.
        try FileManager.default.unzipItem(at: archive, to: destination)

        let enumerator = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var names: [String] = []
        while let item = enumerator?.nextObject() as? URL {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            names.append(item.lastPathComponent)
        }
        return names.sorted()
    }
    /// Relative paths of every entry, including directories. Lets a test assert
    /// that each session folder survived the round trip.
    public static func entryPaths(of archive: URL) throws -> [String] {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("unzip-all-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        try FileManager.default.unzipItem(at: archive, to: destination)

        let enumerator = FileManager.default.enumerator(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        var paths: [String] = []
        while let item = enumerator?.nextObject() as? URL {
            let relative = item.path.replacingOccurrences(of: destination.path + "/", with: "")
            paths.append(relative)
        }
        return paths.sorted()
    }
    #endif
}

public enum ArchiveError: Error, CustomStringConvertible, Equatable {
    case missingSession(String)
    case failed(String)

    public var description: String {
        switch self {
        case .missingSession(let id): return "Session \(id) not found"
        case .failed(let message): return "Export failed: \(message)"
        }
    }
}

#if os(macOS)
private extension FileManager {
    /// `unzipItem` is provided by Foundation on Apple platforms; declared here so
    /// the call site reads clearly.
    func unzipItem(at source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", source.path, destination.path]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ArchiveError.failed("could not read archive (status \(process.terminationStatus))")
        }
    }
}
#endif
