import Foundation
import OBDLink

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

final class SessionLogger: ELMLogger {
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
    case disallowedService(UInt8)

    var description: String {
        switch self {
        case .ignitionTimeout(let s):
            return "No ECU response after \(s)s. Check ignition is ON and the dongle is fully seated."
        case .noData(let c):
            return "No usable data for command '\(c)'"
        case .disallowedService(let service):
            return String(
                format: "Service %02X is not a read-only sweep service. Allowed: 21, 22 and 1A.",
                service)
        }
    }
}
