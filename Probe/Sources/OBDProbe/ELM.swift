import Foundation

/// A parsed ELM327 reply.
struct ELMResponse {
    let command: String
    let raw: String
    let lines: [String]

    static let statusPhrases = [
        "SEARCHING...",
        "SEARCHING",
        "BUS INIT: ...OK",
        "BUS INIT: OK",
        "BUS INIT: ...ERROR",
        "BUS INIT: ERROR",
        "NO DATA",
        "UNABLE TO CONNECT",
        "STOPPED",
        "?",
        "ERROR",
        "CAN ERROR",
        "BUFFER FULL",
        "BUS BUSY",
        "FB ERROR",
        "DATA ERROR",
        "<DATA ERROR",
        "<RX ERROR",
        "LV RESET",
        "ACT ALERT"
    ]

    var promptSeen: Bool { raw.contains(">") }
    var isEmpty: Bool { lines.isEmpty }

    /// Every response frame, as hex, in the order the adapter returned them.
    ///
    /// A single request can legitimately produce more than one frame: with headers
    /// off, every module that answers a broadcast mode 01 request appears here. So
    /// frames are kept separate and never concatenated — joining them invents DTCs
    /// and corrupts multi-byte values.
    var payloadFrames: [String] {
        let hasFramePrefixes = lines.contains {
            $0.range(of: "^[0-9A-F]:", options: [.regularExpression, .caseInsensitive]) != nil
        }

        func isStatusLine(_ text: String) -> Bool {
            let upper = text.uppercased()
            if ELMResponse.statusPhrases.contains(where: { upper == $0 }) { return true }
            if upper.hasPrefix("SEARCHING") { return true }
            if upper.hasPrefix("BUS INIT") { return true }
            return false
        }

        if hasFramePrefixes {
            // ISO-TP multi-frame: "014" then "0:" / "1:" chunks. One group per
            // multi-frame message, split wherever a "0:" chunk starts again.
            var groups: [String] = []
            var current = ""
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !isStatusLine(t) else { continue }
                guard let colon = t.firstIndex(of: ":"), colon > t.startIndex else { continue }
                let prefix = String(t[t.startIndex..<colon]).uppercased()
                guard prefix.count <= 3, prefix.allSatisfy({ $0.isHexDigit }) else { continue }
                var body = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                guard looksLikeHex(body) else { continue }
                body = body.replacingOccurrences(of: " ", with: "")
                if prefix == "0", !current.isEmpty {
                    groups.append(current)
                    current = ""
                }
                current += body
            }
            if !current.isEmpty { groups.append(current) }
            return groups
        }

        var frames: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !isStatusLine(t), looksLikeHex(t) else { continue }
            frames.append(t.replacingOccurrences(of: " ", with: ""))
        }
        return frames
    }

    /// First response frame. Use this for single-module queries.
    var payloadHex: String? { payloadFrames.first }

    var payloadBytes: [UInt8]? {
        guard let hex = payloadHex else { return nil }
        return bytesFromHex(hex)
    }

    /// Data bytes of the first frame, with the 2-byte mode/PID echo removed.
    var dataBytes: [UInt8]? {
        guard let bytes = payloadBytes, bytes.count > 2 else { return nil }
        return Array(bytes[2...])
    }

    /// True when more than one module answered the request.
    var hasMultipleFrames: Bool { payloadFrames.count > 1 }

    var statusSummary: String {
        let frames = payloadFrames
        if !frames.isEmpty { return frames.joined(separator: " | ") }
        let meaningful = lines.filter { !$0.isEmpty }
        return meaningful.isEmpty ? "(empty reply)" : meaningful.joined(separator: " / ")
    }

    var failed: Bool {
        let joined = lines.joined(separator: " ").uppercased()
        return ["NO DATA", "UNABLE TO CONNECT", "STOPPED", "ERROR", "?"].contains {
            joined.contains($0)
        }
    }
}

final class ELMClient: ELMSource {
    private let transport: BLETransport
    private let logger: SessionLogger?

    init(transport: BLETransport, logger: SessionLogger?) {
        self.transport = transport
        self.logger = logger
    }

    @discardableResult
    func send(_ command: String, timeout: TimeInterval = 3.0) async throws -> ELMResponse {
        let started = Date()
        let raw = try await transport.request(command, timeout: timeout)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let response = ELMClient.parse(command: command, raw: raw, elapsedMS: elapsed)

        logger?.raw([
            "t": isoNow(),
            "cmd": command,
            "raw": raw.replacingOccurrences(of: "\r", with: "\\r")
                      .replacingOccurrences(of: "\n", with: "\\n"),
            "hex": hexString(Data(raw.utf8)),
            "ms": elapsed,
            "payload": response.payloadHex ?? ""
        ])

        return response
    }

    static func parse(command: String, raw: String, elapsedMS: Int = 0) -> ELMResponse {
        var text = raw
        if let prompt = text.range(of: ">", options: .backwards) {
            text = String(text[..<prompt.lowerBound])
        }

        let cmdKey = command.uppercased()
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")

        var lines = text
            .replacingOccurrences(of: "\n", with: "\r")
            .components(separatedBy: "\r")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Drop the echoed command, with or without spaces.
        lines.removeAll {
            $0.uppercased().replacingOccurrences(of: " ", with: "") == cmdKey
        }

        return ELMResponse(command: command, raw: raw, lines: lines)
    }
}
