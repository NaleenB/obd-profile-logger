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
    public let notes: [String]
    public let service: Service
    public let blocks: [Block]
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
