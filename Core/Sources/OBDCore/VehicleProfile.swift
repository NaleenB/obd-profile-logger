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

    /// The engine module's request header, when the profile identifies one.
    ///
    /// Standard OBD is normally read by broadcast, but a vehicle can have more
    /// than one module answering `7DF`. Addressing the engine explicitly keeps
    /// the transmission's speed or capability bitmap out of the engine values.
    public var engineRequestHeader: String? {
        if let ecm = transport?.modules.first(where: {
            $0.name.caseInsensitiveCompare("ECM") == .orderedSame
        }) {
            return ecm.requestHeader
        }
        // CAN 11/500 uses the standard engine address even when a profile has
        // not enumerated its modules.
        if transport?.elmProtocol == "6" { return "7E0" }
        return nil
    }

    /// Header to use for standard mode-`01` traffic. Broadcast is the fallback
    /// for protocols where the engine address is not known.
    public var standardRequestHeader: String { engineRequestHeader ?? "7DF" }

    /// Header to use for manufacturer reads. Mitsubishi service `0x21` is
    /// addressed to the engine module; profiles for other buses can override it
    /// by naming an ECM module. With no engine address, broadcast is safer than
    /// inventing a CAN engine header on an unknown protocol.
    public var manufacturerRequestHeader: String { engineRequestHeader ?? "7DF" }

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

    /// How to recognise this vehicle from the data it reports.
    ///
    /// Mode 09 identity (VIN, calibration ID) is the preferred proof, but it can
    /// be unreadable while the ECU is asleep. These rules let the app test a
    /// profile against the car instead: decode a manufacturer item and compare it
    /// with the same quantity from standard OBD. A wrong layout produces a byte
    /// unrelated to the quantity, so it cannot pass.
    public struct IdentitySpec: Codable, Equatable {
        /// Local identifiers to read when gathering evidence. Keep this to a few
        /// blocks: the probe runs while the engine is running and should cost
        /// well under a second.
        public let probeLIDs: [String]
        public let discriminators: [Discriminator]
        public let plausibility: [PlausibilityRule]?

        public var lidValues: [UInt8] { probeLIDs.compactMap { UInt8($0, radix: 16) } }
    }

    /// One quantity the profile claims to know, paired with the standard PID that
    /// reports the same thing independently.
    public struct Discriminator: Codable, Equatable {
        public let itemNumber: Int
        /// Standard OBD-II PID reporting the same quantity, hex.
        public let sameAsPID: String
        public let tolerance: Double
        public let weight: Double
        /// A required discriminator must agree before the profile is applied.
        /// Engine speed is required: it changes fast, so a wrong byte cannot
        /// track it.
        public let required: Bool?
        /// The comparison only means something above this standard value. Engine
        /// speed needs 400 rpm, because with the engine off every profile agrees
        /// on zero.
        public let minimumStandard: Double?

        public var pidValue: UInt8? { UInt8(sameAsPID, radix: 16) }
    }

    /// A range check that supports identification without needing a reference
    /// value, such as a plausible odometer.
    public struct PlausibilityRule: Codable, Equatable {
        public let itemNumber: Int
        public let min: Double
        public let max: Double
        public let weight: Double
    }

    /// A named parameter this profile can expose to a feature without the app
    /// knowing its manufacturer's item number.
    public struct Role: Codable, Equatable {
        /// Local identifier, so a role stays unambiguous when item numbers repeat
        /// across blocks.
        public let lid: String?
        public let itemNumber: Int

        public var lidValue: UInt8? { lid.flatMap { UInt8($0, radix: 16) } }

        public func value(in parameters: some Sequence<DecodedParameter>) -> Double? {
            parameters.first { parameter in
                parameter.itemNumber == itemNumber
                    && (lidValue == nil || parameter.lid == lidValue)
            }?.value
        }
    }

    /// Optional meanings the app may attach to otherwise generic parameters.
    /// A profile without roles remains fully decodable; features that need a
    /// role simply do not appear.
    public struct Roles: Codable, Equatable {
        /// Parameters worth showing without scrolling, by data-list item number.
        public let highlights: [Int]?
        /// Live blocks that should be refreshed every polling cycle.
        public let priorityLIDs: [String]?
        /// Blocks captured at each end of a session.
        public let tripSnapshotLIDs: [String]?
        public let odometer: Role?
        public let dpfTemperature: Role?
        public let sootByAccumulation: Role?
        public let sootByPressure: Role?
        public let regenerationCount: Role?
        public let regenerationMode: Role?
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
    public let roles: Roles?
    public let service: Service
    public let transport: Transport?
    public let standard: [StandardSignal]?
    public let blocks: [Block]
    /// Absent means the profile can only be matched by calibration ID or VIN.
    public let identity: IdentitySpec?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, manufacturer, model, year, engine, market
        case calibrationIDs, vinPrefixes, notes, roles, service, transport
        case standard, blocks, identity
    }

    /// A profile is an extension point, so fields the schema calls optional must
    /// really be optional. Synthesized Codable would otherwise require `notes`
    /// and `blocks` even though an incomplete profile is supposed to degrade to
    /// generic decoding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        model = try container.decode(String.self, forKey: .model)
        year = try container.decode(Int.self, forKey: .year)
        engine = try container.decode(String.self, forKey: .engine)
        market = try container.decodeIfPresent(String.self, forKey: .market)
        calibrationIDs = try container.decodeIfPresent([String].self, forKey: .calibrationIDs)
        vinPrefixes = try container.decodeIfPresent([String].self, forKey: .vinPrefixes)
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        roles = try container.decodeIfPresent(Roles.self, forKey: .roles)
        service = try container.decode(Service.self, forKey: .service)
        transport = try container.decodeIfPresent(Transport.self, forKey: .transport)
        standard = try container.decodeIfPresent([StandardSignal].self, forKey: .standard)
        blocks = try container.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        identity = try container.decodeIfPresent(IdentitySpec.self, forKey: .identity)
    }

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
            let profile = try JSONDecoder().decode(VehicleProfile.self, from: data)
            try profile.validate()
            return profile
        } catch let error as VehicleProfileError {
            throw error
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

extension VehicleProfile {

    /// Reject a profile that cannot be interpreted safely.
    ///
    /// JSON decoding alone accepts negative byte lengths, duplicate identifiers
    /// and `observed` evidence that disagrees with the emitted scaling. Those
    /// mistakes are silent at runtime, which is precisely how a profile becomes
    /// trusted when it should not be.
    func validate() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw VehicleProfileError.malformed(message) }
        }

        try require(schemaVersion == 1, "unsupported schemaVersion \(schemaVersion)")
        try require(!id.isEmpty, "profile id is empty")
        try require(!manufacturer.isEmpty, "manufacturer is empty")
        try require(!model.isEmpty, "model is empty")
        try require(!engine.isEmpty, "engine is empty")

        var seenLIDs = Set<UInt8>()
        var parametersByLID: [UInt8: [Int: VehicleProfile.Parameter]] = [:]
        for block in blocks {
            guard let lid = block.lidValue else {
                throw VehicleProfileError.malformed("block lid '\(block.lid)' is not a hex byte")
            }
            try require(seenLIDs.insert(lid).inserted, "duplicate block lid \(block.lid)")
            var items: [Int: VehicleProfile.Parameter] = [:]
            for parameter in block.parameters {
                try require(!parameter.name.isEmpty, "a parameter in LID \(block.lid) has no name")
                try require(parameter.byte >= 0, "\(parameter.name) has a negative byte offset")
                try require((1...8).contains(parameter.length),
                           "\(parameter.name) has unsupported length \(parameter.length)")
                try require(parameter.factor.isFinite && parameter.offset.isFinite,
                           "\(parameter.name) has non-finite scaling")
                if let observed = parameter.observed {
                    let expected = Double(observed.raw) * parameter.factor + parameter.offset
                    try require(abs(expected - observed.value) < 0.000_001,
                               "\(parameter.name) observed value \(observed.value) does not match scaling (expected \(expected))")
                }
                if let item = parameter.itemNumber {
                    // An item number can describe more than one labelled field
                    // in the same block. Roles carry the LID and item together,
                    // so that ambiguity is handled at the role boundary.
                    items[item] = items[item] ?? parameter
                }
            }
            parametersByLID[lid] = items
        }

        var seenPIDs = Set<UInt8>()
        for signal in signals {
            guard let pid = signal.pidValue else {
                throw VehicleProfileError.malformed("standard PID '\(signal.pid)' is not a hex byte")
            }
            try require(seenPIDs.insert(pid).inserted, "duplicate standard PID \(signal.pid)")
            try require(signal.bytes == 1 || signal.bytes == 2,
                       "PID \(signal.pid) must use one or two bytes")
            try require(signal.factor.isFinite && signal.offset.isFinite,
                       "PID \(signal.pid) has non-finite scaling")
            try require((0...6).contains(signal.decimals),
                       "PID \(signal.pid) has an unsupported display precision")
        }

        if let transport {
            try require(!transport.elmProtocol.isEmpty, "transport has an empty elmProtocol")
            for module in transport.modules {
                try require(module.requestHeader.count == 3
                            && UInt16(module.requestHeader, radix: 16) != nil,
                           "module \(module.name) has an invalid request header")
                if let response = module.responseHeader {
                    try require(response.count == 3 && UInt16(response, radix: 16) != nil,
                               "module \(module.name) has an invalid response header")
                }
            }
        }

        if let identity {
            var probeLIDs = Set<UInt8>()
            for raw in identity.probeLIDs {
                guard let lid = UInt8(raw, radix: 16) else {
                    throw VehicleProfileError.malformed("identity probe LID '\(raw)' is not a hex byte")
                }
                try require(parametersByLID[lid] != nil, "identity probe LID \(raw) has no block")
                probeLIDs.insert(lid)
            }
            try require(identity.discriminators.contains { $0.required == true },
                       "identity needs at least one required discriminator")
            let probeItems = Set(probeLIDs.flatMap { Array(parametersByLID[$0]?.keys ?? [:].keys) })
            for rule in identity.discriminators {
                try require(probeItems.contains(rule.itemNumber),
                           "identity item \(rule.itemNumber) is not in a probe block")
                if let pid = rule.pidValue {
                    try require(seenPIDs.contains(pid),
                               "identity PID \(rule.sameAsPID) is not polled")
                } else {
                    throw VehicleProfileError.malformed("identity PID '\(rule.sameAsPID)' is not a hex byte")
                }
                try require(rule.tolerance >= 0 && rule.weight >= 0,
                           "identity item \(rule.itemNumber) has invalid tolerance or weight")
            }
            for rule in identity.plausibility ?? [] {
                try require(probeItems.contains(rule.itemNumber),
                           "plausibility item \(rule.itemNumber) is not in a probe block")
                try require(rule.min <= rule.max,
                           "plausibility item \(rule.itemNumber) has min above max")
            }
        }

        if let roles {
            for item in roles.highlights ?? [] {
                try require(parametersByLID.values.contains { $0[item] != nil },
                           "highlight item \(item) is not defined")
            }
            func check(_ role: Role?, _ name: String) throws {
                guard let role else { return }
                guard let lid = role.lidValue else {
                    throw VehicleProfileError.malformed("\(name) role has no valid LID")
                }
                try require(parametersByLID[lid]?[role.itemNumber] != nil,
                           "\(name) role points at item \(role.itemNumber) in LID \(role.lid ?? "?")")
            }
            try check(roles.odometer, "odometer")
            try check(roles.dpfTemperature, "DPF temperature")
            try check(roles.sootByAccumulation, "soot by accumulation")
            try check(roles.sootByPressure, "soot by pressure")
            try check(roles.regenerationCount, "regeneration count")
            try check(roles.regenerationMode, "regeneration mode")
            for raw in roles.priorityLIDs ?? [] {
                guard let lid = UInt8(raw, radix: 16) else {
                    throw VehicleProfileError.malformed("priority LID '\(raw)' is not a hex byte")
                }
                try require(parametersByLID[lid] != nil, "priority LID \(raw) has no block")
            }
            for raw in roles.tripSnapshotLIDs ?? [] {
                guard let lid = UInt8(raw, radix: 16) else {
                    throw VehicleProfileError.malformed("snapshot LID '\(raw)' is not a hex byte")
                }
                try require(parametersByLID[lid] != nil, "snapshot LID \(raw) has no block")
            }
        }
    }
}

public extension VehicleProfile {

    var localIdentifiers: [UInt8] {
        blocks.compactMap(\.lidValue)
    }

    var priorityLIDs: [UInt8] {
        (roles?.priorityLIDs ?? []).compactMap { UInt8($0, radix: 16) }
    }

    var tripSnapshotLIDs: [UInt8] {
        (roles?.tripSnapshotLIDs ?? []).compactMap { UInt8($0, radix: 16) }
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

    /// Parameters worth showing without scrolling. The choice belongs to the
    /// vehicle profile, not to generic decoding code.
    func highlights(from decoded: [DecodedParameter]) -> [DecodedParameter] {
        let wanted = Set(roles?.highlights ?? [])
        return decoded
            .filter { parameter in
                guard let item = parameter.itemNumber else { return false }
                return wanted.contains(item)
            }
            .sorted { ($0.itemNumber ?? 0) < ($1.itemNumber ?? 0) }
    }
}
