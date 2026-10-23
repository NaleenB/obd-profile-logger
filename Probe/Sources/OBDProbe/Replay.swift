import Foundation

/// Anything that can answer an ELM327 command. Lets the probe run against a
/// recorded session instead of a car.
protocol ELMSource {
    func send(_ command: String, timeout: TimeInterval) async throws -> ELMResponse
}

extension ELMSource {
    func send(_ command: String) async throws -> ELMResponse {
        try await send(command, timeout: 3.0)
    }
}

/// Replays a `raw_log.ndjson` captured by an earlier run.
///
/// Responses are served per command in first-in-first-out order, which matches
/// the probe's own sequence. Re-analysing a log is how parser fixes get validated
/// without sitting in the car with the ignition on.
final class ReplayELM: ELMSource {
    private var queues: [String: [String]] = [:]
    private(set) var commandCount = 0

    init(logURL: URL) throws {
        let text = try String(contentsOf: logURL, encoding: .utf8)

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["cmd"] as? String,
                  let raw = object["raw"] as? String
            else { continue }

            // The log stores CR/LF escaped so each record stays on one line.
            let decoded = raw
                .replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\n", with: "\n")

            queues[command.uppercased(), default: []].append(decoded)
            commandCount += 1
        }

        guard commandCount > 0 else {
            throw ProbeError.noData("replay log contained no commands")
        }
    }

    var recordedCommands: [String] {
        queues.keys.sorted()
    }

    func send(_ command: String, timeout: TimeInterval) async throws -> ELMResponse {
        let key = command.uppercased()
        guard var queue = queues[key], !queue.isEmpty else {
            throw ProbeError.noData("no recorded response for '\(command)'")
        }
        let raw = queue.removeFirst()
        queues[key] = queue
        return ELMClient.parse(command: command, raw: raw)
    }
}
