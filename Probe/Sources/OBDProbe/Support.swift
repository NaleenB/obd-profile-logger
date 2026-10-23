import Foundation

// MARK: - Output

func say(_ s: String = "") {
    print(s)
    fflush(stdout)
}

func sayErr(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}

func sayInline(_ s: String) {
    print(s, terminator: "")
    fflush(stdout)
}

// MARK: - Remembered adapter

/// These dongles frequently advertise neither a local name nor any service UUID,
/// so name matching is unreliable. Once we have identified one by talking to it,
/// remember its identifier so later runs connect instantly.
enum KnownAdapter {
    private static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".obdlogger", isDirectory: true)
            .appendingPathComponent("adapter.json")
    }

    static func load() -> (uuid: UUID, name: String)? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let raw = object["uuid"], let uuid = UUID(uuidString: raw)
        else { return nil }
        return (uuid, object["name"] ?? "")
    }

    static func save(uuid: UUID, name: String) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object = ["uuid": uuid.uuidString, "name": name]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        else { return }
        try? data.write(to: fileURL)
    }
}

func rule(_ title: String) {
    say("")
    say(String(repeating: "-", count: 66))
    say("  " + title)
    say(String(repeating: "-", count: 66))
}

// MARK: - Time

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func isoNow() -> String { isoFormatter.string(from: Date()) }

func clockStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

func folderStamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

// MARK: - Hex

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func bytesFromHex(_ s: String) -> [UInt8]? {
    let cleaned = s.filter { !$0.isWhitespace }
    guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    out.reserveCapacity(cleaned.count / 2)
    var idx = cleaned.startIndex
    while idx < cleaned.endIndex {
        let next = cleaned.index(idx, offsetBy: 2)
        guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
        out.append(b)
        idx = next
    }
    return out
}

/// True when every visible character is a hex digit (used to reject NO DATA / UNABLE TO CONNECT).
func looksLikeHex(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty else { return false }
    return t.allSatisfy { $0.isHexDigit || $0 == " " }
}

// MARK: - Session logger

final class SessionLogger {
    let directory: URL
    private let rawURL: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        rawURL = directory.appendingPathComponent("raw_log.ndjson")
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: rawURL)
    }

    func raw(_ record: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        lock.lock()
        handle.write(data)
        handle.write(Data("\n".utf8))
        lock.unlock()
    }

    func write(_ name: String, _ text: String) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func writeJSON(_ name: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(name))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}

// MARK: - Errors

enum ProbeError: Error, CustomStringConvertible {
    case ignitionTimeout(Int)
    case noData(String)

    var description: String {
        switch self {
        case .ignitionTimeout(let s):
            return "No ECU response after \(s)s. Check ignition is ON and the dongle is fully seated."
        case .noData(let c):
            return "No usable data for command '\(c)'"
        }
    }
}
