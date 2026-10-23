import Foundation

/// Step-at-a-time DTC scan across modules.
///
/// A state machine rather than a blocking call, because the OBD transport is
/// serialised: running a full scan inline would stall live sampling for several
/// seconds. The caller issues one command per polling iteration, so live reads
/// and the scan interleave.
///
/// Every query keeps its outcome, so "no codes" is never confused with "no
/// answer" or "this ECU does not support the service".
public struct DTCScanner {

    public struct Target: Equatable, Sendable {
        public let module: String
        public let header: String
        public init(module: String, header: String) {
            self.module = module
            self.header = header
        }
    }

    public enum Step: Equatable {
        case command(String)
        case finished
    }

    public enum Outcome: String, Equatable {
        case ok
        case empty
        case noReply = "no_reply"
        case rejected
        case malformed
    }

    /// The modules this tool targets. ABS, SRS, AWD and body controllers do not
    /// answer generic OBD here and are deliberately excluded.
    public static let defaultTargets: [Target] = [
        Target(module: "ECM", header: "7E0"),
        Target(module: "TCM", header: "7E1")
    ]

    private let targets: [Target]
    private var moduleIndex = 0
    private var phase = 0
    private var pendingModule: String?
    private var pendingPhase = 0

    private var mil: [String: Bool] = [:]
    private var count: [String: Int] = [:]
    private var stored: [String: [String]?] = [:]
    private var pending: [String: [String]?] = [:]
    private var permanent: [String: [String]?] = [:]
    private var outcomes: [String: Outcome] = [:]

    public init(targets: [Target] = DTCScanner.defaultTargets) {
        self.targets = targets
    }

    public var isFinished: Bool { moduleIndex >= targets.count }

    /// Next command to send, or `.finished`. One request per call.
    public mutating func next() -> Step {
        guard moduleIndex < targets.count else { return .finished }
        let target = targets[moduleIndex]

        let command: String
        switch phase {
        case 0: command = "ATSH" + target.header
        case 1: command = "0101"
        case 2: command = "03"
        case 3: command = "07"
        default: command = "0A"
        }

        pendingModule = target.module
        pendingPhase = phase
        return .command(command)
    }

    /// Feed the raw payload for the command just returned. `nil` means no reply
    /// or a timeout.
    public mutating func ingest(responseHex: String?) {
        guard let module = pendingModule else { return }
        defer {
            pendingModule = nil
            phase += 1
            if phase > 4 {
                phase = 0
                moduleIndex += 1
            }
        }

        // ATSH only needs an "OK"; nothing to store.
        guard pendingPhase > 0 else { return }

        if pendingPhase == 1 {
            applyMonitorStatus(module: module, hex: responseHex)
            return
        }

        let mode: String
        switch pendingPhase {
        case 2: mode = "stored"
        case 3: mode = "pending"
        default: mode = "permanent"
        }
        applyCodes(module: module, mode: mode, hex: responseHex, phase: pendingPhase)
    }

    private mutating func applyMonitorStatus(module: String, hex: String?) {
        guard let hex else {
            outcomes["\(module).monitor"] = .noReply
            return
        }
        if hex.hasPrefix("7F") {
            outcomes["\(module).monitor"] = .rejected
            return
        }
        guard hex.hasPrefix("4101"),
              let bytes = DTCScanner.bytes(String(hex.dropFirst(4))),
              bytes.count >= 2
        else {
            outcomes["\(module).monitor"] = .malformed
            return
        }
        mil[module] = (bytes[0] & 0x80) != 0
        count[module] = Int(bytes[0] & 0x7F)
        outcomes["\(module).monitor"] = .ok
    }

    private mutating func applyCodes(module: String, mode: String, hex: String?, phase: Int) {
        let key = "\(module).\(mode)"

        guard let hex else {
            outcomes[key] = .noReply
            setCodes(nil, module: module, mode: mode)
            return
        }
        if hex.hasPrefix("7F") {
            // 7F <service> <NRC>: the ECU refused the request.
            outcomes[key] = .rejected
            setCodes(nil, module: module, mode: mode)
            return
        }

        let header = phase == 2 ? "43" : (phase == 3 ? "47" : "4A")
        guard hex.hasPrefix(header), let codes = DTCDecoder.codes(fromHex: String(hex.dropFirst(2))) else {
            outcomes[key] = .malformed
            setCodes(nil, module: module, mode: mode)
            return
        }

        outcomes[key] = codes.isEmpty ? .empty : .ok
        setCodes(codes, module: module, mode: mode)
    }

    private mutating func setCodes(_ codes: [String]?, module: String, mode: String) {
        switch mode {
        case "stored": stored[module] = codes
        case "pending": pending[module] = codes
        default: permanent[module] = codes
        }
    }

    /// Aggregated results. A module is complete only when every query answered.
    public var diagnostics: VehicleDiagnostics {
        let modules = targets.map { target -> ModuleDiagnostics in
            ModuleDiagnostics(
                module: target.module,
                header: target.header,
                milOn: mil[target.module],
                reportedDTCs: count[target.module],
                stored: stored[target.module] ?? nil,
                pending: pending[target.module] ?? nil,
                permanent: permanent[target.module] ?? nil
            )
        }
        return VehicleDiagnostics(modules: modules)
    }

    /// Per-query outcomes, for the event stream.
    public var outcomeDetails: [String: String] {
        outcomes.mapValues(\.rawValue)
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
