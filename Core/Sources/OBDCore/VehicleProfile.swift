import Foundation

/// A vehicle profile: the data that makes the engine vehicle-specific.
///
/// See `profiles/README.md` for the schema. Nothing here is Mitsubishi-specific;
/// the shipped profile is just one instance.
public struct VehicleProfile: Codable, Equatable {

    public struct Service: Codable, Equatable {
        public let readByLocalIdentifier: String?
        public let readByIdentifier: String?
    }

    /// A module that answers diagnostic requests, with its CAN request header.
    public struct Module: Codable, Equatable {
        public let name: String
        public let requestHeader: String
        public let responseHeader: String?
    }

    /// How to talk to the vehicle at all. Absent means "assume the defaults".
    public struct Transport: Codable, Equatable {
        /// ELM327 `ATSP` value: "6" is CAN 11/500, "0" is auto-detect.
        public let elmProtocol: String
        public let description: String?
        public let modules: [Module]
    }

    /// One standard OBD-II signal, described as data rather than decoded in code:
    /// `value = raw * factor + offset`, read big-endian over `bytes` bytes.
    public struct StandardSignal: Codable, Equatable, Identifiable, Sendable {
        public let pid: String
        public let name: String
        public let unit: String
        public let bytes: Int
        public let factor: Double
        public let offset: Double
        public let decimals: Int

        public var id: String { pid }
        public var pidValue: UInt8? { UInt8(pid, radix: 16) }

        public func decode(_ data: [UInt8]) -> Double? {
            guard bytes == 1 || bytes == 2, data.count >= bytes else { return nil }
            let raw: UInt32
            if bytes == 1 {
                raw = UInt32(data[0])
            } else {
                raw = (UInt32(data[0]) << 8) | UInt32(data[1])
            }
            return Double(raw) * factor + offset
        }

        public func formatted(_ value: Double) -> String {
            String(format: "%.\(decimals)f", value)
        }
    }

    public struct Observed: Codable, Equatable {
        public let raw: Int
        public let value: Double
    }

    public struct Parameter: Codable, Equatable {
        public let itemNumber: Int?
        public let name: String
        /// Absolute offset within the response frame, counting the service byte
        /// and the local identifier. See `profiles/README.md`.
        public let byte: Int
        public let length: Int
        public let factor: Double
        public let offset: Double
        public let unit: String?
        public let observed: Observed?
        /// Raw values that mean "no measurement", not a reading: a sensor the
        /// vehicle does not have, or a field the ECU leaves at its clamp.
        /// Parameters matching these are omitted rather than shown as a number.
        public let unavailableRaw: [Int]?
    }

    public struct Block: Codable, Equatable {
        public let lid: String
        public let parameters: [Parameter]

        /// Local identifier as a byte, or nil when the profile is malformed.
        public var lidValue: UInt8? { UInt8(lid, radix: 16) }
    }

    public let schemaVersion: Int
    public let id: String
    public let manufacturer: String
    public let model: String
    public let year: Int
    public let engine: String
    public let market: String?
    /// Calibration identifiers this profile applies to. The precise way to match
    /// a profile: byte layouts differ between ECU software versions.
    public let calibrationIDs: [String]?
    /// VIN prefixes this profile applies to, as a fallback when the calibration
    /// ID is unavailable.
    public let vinPrefixes: [String]?
    public let notes: [String]
    public let service: Service
    public let transport: Transport?
    public let standard: [StandardSignal]?
    public let blocks: [Block]

    /// Standard signals to poll, falling back to an empty list rather than
    /// inventing a set.
    public var signals: [StandardSignal] { standard ?? [] }

    /// Modules to scan for DTCs. Empty when the profile does not say.
    public var diagnosticModules: [Module] { transport?.modules ?? [] }

    /// ELM protocol selector, or nil to leave the adapter on auto-detect.
    public var elmProtocol: String? {
        guard let value = transport?.elmProtocol, !value.isEmpty, value != "0" else { return nil }
        return value
    }
}

public struct DecodedParameter: Equatable, Identifiable {
    public let lid: UInt8
    public let itemNumber: Int?
    public let name: String
    public let unit: String?
    public let value: Double

    public var id: String { "\(lid):\(name)" }

    public var displayValue: String {
        let digits = abs(value) >= 100 ? 0 : (abs(value) >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f", value)
    }
}

public enum VehicleProfileError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case malformed(String)

    public var description: String {
        switch self {
        case .notFound(let name): return "Profile not found: \(name)"
        case .malformed(let reason): return "Profile could not be read: \(reason)"
        }
    }
}

public enum VehicleProfileLoader {

    public static func load(from url: URL) throws -> VehicleProfile {
        guard let data = try? Data(contentsOf: url) else {
            throw VehicleProfileError.notFound(url.lastPathComponent)
        }
        do {
            return try JSONDecoder().decode(VehicleProfile.self, from: data)
        } catch {
            throw VehicleProfileError.malformed(error.localizedDescription)
        }
    }

    public static func load(named name: String, in bundle: Bundle = .main) throws -> VehicleProfile {
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw VehicleProfileError.notFound(name)
        }
        return try load(from: url)
    }
}

public extension VehicleProfile {

    var localIdentifiers: [UInt8] {
        blocks.compactMap(\.lidValue)
    }

    /// Decodes every parameter in a frame, skipping values that fall outside the
    /// response (short replies are normal during a multi-frame read).
    func decode(_ frame: MUT21Frame) -> [DecodedParameter] {
        guard let block = blocks.first(where: { $0.lidValue == frame.localIdentifier }) else {
            return []
        }
        return block.parameters.compactMap { parameter in
            guard let raw = frame.value(at: parameter.byte, length: parameter.length) else {
                return nil
            }
            // A pinned sentinel is the absence of a measurement, not a reading.
            if let unavailable = parameter.unavailableRaw, unavailable.contains(raw) {
                return nil
            }
            let value = Double(raw) * parameter.factor + parameter.offset
            return DecodedParameter(
                lid: frame.localIdentifier,
                itemNumber: parameter.itemNumber,
                name: parameter.name,
                unit: parameter.unit,
                value: value
            )
        }
    }

    /// Parameters worth showing without scrolling, by data-list item number.
    /// Kept explicit so the choice is reviewable rather than guessed by name.
    static let highlightItemNumbers: Set<Int> = [
        16, 17,      // EGR valve position, target
        63, 64,      // rail pressure, target
        116,         // regeneration request mode
        117, 118, 119,  // EGT 1, catalyst, DPF temperature
        127,         // DPF temperature max (stored)
        142, 143,    // VGT duty before/after compensation
        148,         // regeneration count
        153,         // distance since last regeneration
        155, 156,    // soot loading, both models
        191,         // non-uniform soot
        208          // short-interval regeneration rate
    ]

    func highlights(from decoded: [DecodedParameter]) -> [DecodedParameter] {
        decoded
            .filter { parameter in
                guard let item = parameter.itemNumber else { return false }
                return Self.highlightItemNumbers.contains(item)
            }
            .sorted { ($0.itemNumber ?? 0) < ($1.itemNumber ?? 0) }
    }
}
