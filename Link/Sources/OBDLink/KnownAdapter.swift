import Foundation

/// Remembers the last adapter that worked.
///
/// These dongles frequently advertise neither a local name nor any service UUID,
/// so name matching is unreliable. Once one has been identified by talking to
/// it, its identifier makes later connections instant.
public enum KnownAdapter {

    private static var directory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("OBDLogger", isDirectory: true)
    }

    private static var fileURL: URL {
        directory.appendingPathComponent("adapter.json")
    }

    public static func load() -> (uuid: UUID, name: String)? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = object["uuid"], let uuid = UUID(uuidString: raw)
        else { return nil }
        return (uuid, object["name"] ?? "")
    }

    public static func save(uuid: UUID, name: String) {
        let directory = KnownAdapter.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = ["uuid": uuid.uuidString, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        else { return }
        try? data.write(to: fileURL)
    }
}
