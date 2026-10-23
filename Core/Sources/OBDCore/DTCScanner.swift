import Foundation

/// Step-at-a-time DTC scan across modules.
///
/// A state machine rather than a blocking call, because the OBD transport is
/// serialised: running a full scan inline would stall live sampling for several
/// seconds. The caller issues one request per polling iteration, so live reads
/// and the scan interleave.
///
/// **Every request carries its target header.** The header is never assumed to
/// persist between steps: the caller must select it immediately before sending,
/// because other traffic (live sampling, manufacturer sweeps) resets addressing
/// in between. A scanner that emitted `ATSH` once per module would silently be
/// querying whichever module was addressed last.
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

    public struct Request: Equatable, Sendable {
        public let module: String
        public let header: String
        public let command: String
    }

    public enum Step: Equatable {
        case request(Request)
        case finished
    }

    public enum Outcome: String, Equatable {
        case ok
        case empty
        case noReply = "no_reply"
        case rejected
        case malformed
        /// The adapter refused or ignored the header selection, so the query was
        /// never sent. Distinct from "no reply": nothing was asked.
        case headerError = "header_error"
    }

    /// The modules this tool targets. ABS, SRS, AWD and body controllers do not
    /// answer generic OBD here and are deliberately excluded.
    public static let defaultTargets: [Target] = [
        Target(module: "ECM", header: "7E0"),
        Target(module: "TCM", header: "7E1")
    ]

    private static let queries = ["0101", "03", "07", "0A"]

    private let targets: [Target]
    private var moduleIndex = 0
    private var queryIndex = 0
    private var pending: Request?

    private var mil: [String: Bool] = [:]
    private var count: [String: Int] = [:]
    private var stored: [String: [String]?] = [:]
    private var pendingCodes: [String: [String]?] = [:]
    private var permanent: [String: [String]?] = [:]
    private var outcomes: [String: Outcome] = [:]

    public init(targets: [Target] = DTCScanner.defaultTargets) {
        self.targets = targets
    }

    public var isFinished: Bool { moduleIndex >= targets.count }

    /// Next request, or `.finished`. The caller sends `ATSH<header>` and then
    /// `command` as one step.
    public mutating func next() -> Step {
        guard moduleIndex < targets.count else { return .finished }
        let target = targets[moduleIndex]
        let request = Request(
            module: target.module,
            header: target.header,
            command: Self.queries[queryIndex]
        )
        pending = request
        return .request(request)
    }

    /// The adapter did not acknowledge the header selection. The query must not
    /// be sent: without the intended header it would be answered by whichever
    /// module was addressed last, and the result would be attributed to the
    /// wrong ECU.
    public mutating func ingestHeaderFailure() {
        guard let request = pending else { return }
        pending = nil
        outcomes[key(for: request)] = .headerError
        setCodes(nil, module: request.module, mode: mode(for: request))
        advance()
    }

    private mutating func advance() {
        queryIndex += 1
        if queryIndex >= Self.queries.count {
            queryIndex = 0
            moduleIndex += 1
        }
    }

    private func key(for request: Request) -> String {
        let suffix: String
        switch request.command {
        case "0101": suffix = "monitor"
        case "03": suffix = "stored"
        case "07": suffix = "pending"
        default: suffix = "permanent"
        }
        return "\(request.module).\(suffix)"
    }

    private func mode(for request: Request) -> String {
        switch request.command {
        case "03": return "stored"
        case "07": return "pending"
        case "0101": return "monitor"
        default: return "permanent"
        }
    }

    /// Feed the raw payload for the request just returned. `nil` means no reply
    /// or a timeout.
    public mutating func ingest(responseHex: String?) {
        guard let request = pending else { return }
        pending = nil
        defer { advance() }

        switch request.command {
        case "0101":
            applyMonitorStatus(module: request.module, hex: responseHex)
        case "03":
            applyCodes(module: request.module, mode: "stored", hex: responseHex, header: "43")
        case "07":
            applyCodes(module: request.module, mode: "pending", hex: responseHex, header: "47")
        default:
            applyCodes(module: request.module, mode: "permanent", hex: responseHex, header: "4A")
        }
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

    private mutating func applyCodes(module: String, mode: String, hex: String?, header: String) {
        let key = "\(module).\(mode)"

        guard let hex else {
            outcomes[key] = .noReply
            setCodes(nil, module: module, mode: mode)
            return
        }
        if hex.hasPrefix("7F") {
            outcomes[key] = .rejected
            setCodes(nil, module: module, mode: mode)
            return
        }
        guard hex.hasPrefix(header),
              let codes = DTCDecoder.codes(fromHex: String(hex.dropFirst(header.count)))
        else {
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
        case "pending": pendingCodes[module] = codes
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
                pending: pendingCodes[target.module] ?? nil,
                permanent: permanent[target.module] ?? nil
            )
        }
        return VehicleDiagnostics(modules: modules)
    }

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

/// Stable fingerprint of a scan, used to decide whether a new snapshot event is
/// worth writing. Includes everything a reader would care about: MIL state, the
/// ECU's own count, every code list, completeness, and per-query outcomes.
public enum DTCSnapshot {
    public static func signature(_ diagnostics: VehicleDiagnostics,
                                 outcomes: [String: String]) -> String {
        var parts: [String] = []
        for module in diagnostics.modules {
            let mil = module.milOn.map { $0 ? "1" : "0" } ?? "-"
            let count = module.reportedDTCs.map(String.init) ?? "-"
            let stored = module.stored?.joined(separator: ",") ?? "?"
            let pending = module.pending?.joined(separator: ",") ?? "?"
            let permanent = module.permanent?.joined(separator: ",") ?? "?"
            parts.append("\(module.module)|mil=\(mil)|n=\(count)|s=\(stored)|p=\(pending)|x=\(permanent)|c=\(module.isComplete ? 1 : 0)")
        }
        for key in outcomes.keys.sorted() {
            parts.append("o:\(key)=\(outcomes[key] ?? "")")
        }
        return parts.joined(separator: ";")
    }
}
