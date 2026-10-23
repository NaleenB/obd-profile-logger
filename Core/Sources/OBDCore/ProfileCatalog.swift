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
