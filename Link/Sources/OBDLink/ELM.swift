import Foundation

/// Anything that can answer an ELM327 command. Lets the probe run against a
/// recorded session instead of a car.
public protocol ELMSource {
    func send(_ command: String, timeout: TimeInterval) async throws -> ELMResponse
}

public extension ELMSource {
    func send(_ command: String) async throws -> ELMResponse {
        try await send(command, timeout: 3.0)
    }
}

/// Anything that can record a raw ELM327 exchange.
public protocol ELMLogger: AnyObject {
    func raw(_ record: [String: Any])
}

/// A parsed ELM327 reply.
public struct ELMResponse {
    let command: String
    let raw: String
    public let lines: [String]

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

    public var promptSeen: Bool { raw.contains(">") }
    public var isEmpty: Bool { lines.isEmpty }

    /// Every response frame, as hex, in the order the adapter returned them.
    ///
    /// A single request can legitimately produce more than one frame: with headers
    /// off, every module that answers a broadcast mode 01 request appears here. So
    /// frames are kept separate and never concatenated — joining them invents DTCs
    /// and corrupts multi-byte values.
    public var payloadFrames: [String] {
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
    public var payloadHex: String? { payloadFrames.first }

    public var payloadBytes: [UInt8]? {
        guard let hex = payloadHex else { return nil }
        return bytesFromHex(hex)
    }

    /// Data bytes of the first frame, with the 2-byte mode/PID echo removed.
    public var dataBytes: [UInt8]? {
        guard let bytes = payloadBytes, bytes.count > 2 else { return nil }
        return Array(bytes[2...])
    }

    /// Supply voltage reported by `ATRV`, e.g. `"12.4V"`.
    ///
    /// The adapter reads this from the OBD port itself, so it is available even
    /// when the ECU is asleep — which is exactly when a live voltage is worth
    /// showing, and when no PID will answer.
    public var supplyVolts: Double? {
        for line in lines.reversed() {
            var text = line.trimmingCharacters(in: .whitespaces).uppercased()
            if text.hasSuffix("V") { text.removeLast() }
            // A car's electrical system is nowhere near these bounds; anything
            // outside them is a misparsed reply rather than a reading.
            if let volts = Double(text), volts > 5, volts < 30 { return volts }
        }
        return nil
    }

    /// True when more than one module answered the request.
    public var hasMultipleFrames: Bool { payloadFrames.count > 1 }

    public var statusSummary: String {
        let frames = payloadFrames
        if !frames.isEmpty { return frames.joined(separator: " | ") }
        let meaningful = lines.filter { !$0.isEmpty }
        return meaningful.isEmpty ? "(empty reply)" : meaningful.joined(separator: " / ")
    }

    /// True when the adapter answered a configuration command with "OK".
    /// Distinguishes an accepted command from a silent or refused one.
    public var isOK: Bool {
        lines.contains { $0.trimmingCharacters(in: .whitespaces).uppercased() == "OK" }
    }

    public var failed: Bool {
        let joined = lines.joined(separator: " ").uppercased()
        return ["NO DATA", "UNABLE TO CONNECT", "STOPPED", "ERROR", "?"].contains {
            joined.contains($0)
        }
    }
}

public final class ELMClient: ELMSource {
    private let transport: BLETransport
    private let logger: ELMLogger?

    public init(transport: BLETransport, logger: ELMLogger?) {
        self.transport = transport
        self.logger = logger
    }

    @discardableResult
    public func send(_ command: String, timeout: TimeInterval = 3.0) async throws -> ELMResponse {
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

    public static func parse(command: String, raw: String, elapsedMS: Int = 0) -> ELMResponse {
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
