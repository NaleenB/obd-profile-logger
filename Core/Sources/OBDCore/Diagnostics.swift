import Foundation

/// Diagnostic trouble code decoding and per-module aggregation.
///
/// This vehicle answers broadcast OBD requests from both the engine (`7E8`) and
/// transmission (`7E9`) ECUs. Their replies must never be merged: doing so
/// fabricates codes and attributes one module's fault to another. Everything
/// here keeps module identity attached to the codes.
public enum DTCDecoder {

    /// Decodes the data portion of a mode 03/07/0A reply, with the service byte
    /// already removed. Returns nil when the payload cannot be interpreted.
    public static func codes(fromHex hex: String) -> [String]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        // An empty payload means the service replied with no data at all, which
        // is malformed rather than "no codes".
        guard !cleaned.isEmpty, let bytes = bytes(fromHex: cleaned) else { return nil }

        // A single 0x00 byte is the "no codes stored" encoding.
        if bytes.count == 1 {
            return bytes[0] == 0 ? [] : nil
        }
        guard bytes.count.isMultiple(of: 2) else { return nil }

        var codes: [String] = []
        var index = 0
        while index + 1 < bytes.count {
            let pair = [bytes[index], bytes[index + 1]]
            index += 2
            if pair[0] == 0 && pair[1] == 0 { continue }
            codes.append(decode(pair))
        }
        return codes
    }

    public static func decode(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 2 else { return "??" }
        let systems: [Character] = ["P", "C", "B", "U"]
        let system = systems[Int(bytes[0] >> 6)]
        let d1 = (bytes[0] >> 4) & 0x03
        let d2 = bytes[0] & 0x0F
        let d3 = (bytes[1] >> 4) & 0x0F
        let d4 = bytes[1] & 0x0F
        func hex(_ value: UInt8) -> String { String(value, radix: 16, uppercase: true) }
        return "\(system)\(d1)\(hex(d2))\(hex(d3))\(hex(d4))"
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// What one ECU reported. `nil` means the query failed or could not be decoded;
/// that is different from an empty array, which means "asked and there are none".
public struct ModuleDiagnostics: Equatable {
    public let module: String
    public let header: String
    public let milOn: Bool?
    public let reportedDTCs: Int?
    public let stored: [String]?
    public let pending: [String]?
    public let permanent: [String]?

    public init(module: String,
                header: String,
                milOn: Bool? = nil,
                reportedDTCs: Int? = nil,
                stored: [String]? = nil,
                pending: [String]? = nil,
                permanent: [String]? = nil) {
        self.module = module
        self.header = header
        self.milOn = milOn
        self.reportedDTCs = reportedDTCs
        self.stored = stored
        self.pending = pending
        self.permanent = permanent
    }

    /// Every query answered and decoded.
    public var isComplete: Bool {
        milOn != nil && stored != nil && pending != nil && permanent != nil
    }

    public var allCodes: [String] {
        (stored ?? []) + (pending ?? []) + (permanent ?? [])
    }

    public var summary: String {
        guard isComplete else { return "\(module): incomplete" }
        let codes = allCodes
        return codes.isEmpty ? "\(module): no codes" : "\(module): \(codes.joined(separator: ", "))"
    }
}

/// A scan across all modules this tool targets.
public struct VehicleDiagnostics: Equatable {
    public let modules: [ModuleDiagnostics]

    public init(modules: [ModuleDiagnostics]) {
        self.modules = modules
    }

    /// True only when every targeted module answered every query.
    public var isComplete: Bool {
        !modules.isEmpty && modules.allSatisfy(\.isComplete)
    }

    public var modulesIncomplete: [String] {
        modules.filter { !$0.isComplete }.map(\.module)
    }

    /// Codes for one module. Never mixes modules.
    public func codes(for module: String) -> [String] {
        modules.first { $0.module == module }?.allCodes ?? []
    }

    /// All codes, keyed by module, for export.
    public var codesByModule: [String: [String]] {
        var out: [String: [String]] = [:]
        for module in modules { out[module.module] = module.allCodes }
        return out
    }

    public var headline: String {
        if !isComplete {
            return "Incomplete scan — no answer from \(modulesIncomplete.joined(separator: ", "))"
        }
        let total = modules.reduce(0) { $0 + $1.allCodes.count }
        return total == 0 ? "No codes in any module" : "\(total) code(s) across \(modules.count) modules"
    }
}
