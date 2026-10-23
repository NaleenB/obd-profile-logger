import Foundation

/// The profiles shipped inside the app bundle.
///
/// Keeping the list explicit rather than scanning for JSON means a stray
/// resource file cannot silently become a selectable vehicle.
public enum ProfileCatalog {

    public static let defaultID = "mitsubishi-outlander-2016-4n14"

    public struct Entry: Identifiable, Equatable {
        public let id: String
        public let title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Resource file names, without the `.json` extension.
    public static let builtInIDs: [String] = [
        "outlander-2016-4n14",
        "iso15765-can"
    ]

    public static func load(id: String, bundle: Bundle = .main) throws -> VehicleProfile {
        try VehicleProfileLoader.load(named: id, in: bundle)
    }

    /// Which profile to use when the driver has not chosen one.
    ///
    /// Answering a manufacturer service is **not** sufficient evidence: several
    /// models answer `0x21` with entirely different block layouts, so the same
    /// offsets would decode to nonsense. A specific profile is only chosen when
    /// the car's calibration ID or VIN actually matches it. Otherwise the
    /// generic profile is used and the caller is expected to say why.
    public static func automaticID(
        manufacturerAvailable: Bool,
        identity: VehicleIdentity = VehicleIdentity(),
        among profiles: [VehicleProfile]
    ) -> String? {
        if manufacturerAvailable {
            let specific = profiles.first { profile in
                profile.manufacturer != "Generic" && matches(profile, identity)
            }
            if let specific { return specific.id }
        }
        if let generic = profiles.first(where: { $0.manufacturer == "Generic" }) {
            return generic.id
        }
        return profiles.first?.id
    }

    /// True when the profile declares this car specifically.
    public static func matches(_ profile: VehicleProfile, _ identity: VehicleIdentity) -> Bool {
        if let calibrationID = identity.calibrationID,
           let known = profile.calibrationIDs,
           known.contains(calibrationID) {
            return true
        }
        if let vin = identity.vin,
           let prefixes = profile.vinPrefixes,
           prefixes.contains(where: { !$0.isEmpty && vin.hasPrefix($0) }) {
            return true
        }
        return false
    }

    /// Loaded profiles with a human title, skipping any that fail to parse
    /// rather than failing the whole catalogue.
    public static func entries(bundle: Bundle = .main) -> [Entry] {
        builtInIDs.compactMap { file in
            guard let profile = try? load(id: file, bundle: bundle) else { return nil }
            let title = profile.manufacturer == "Generic"
                ? "Generic CAN"
                : "\(profile.manufacturer) \(profile.model)"
            return Entry(id: profile.id, title: title)
        }
    }
}
