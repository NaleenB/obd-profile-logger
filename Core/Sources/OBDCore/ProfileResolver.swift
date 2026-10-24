import Foundation

/// Chooses a vehicle profile from evidence, never from a preference.
///
/// The order is deliberate: calibration ID is the sharpest test because byte
/// layouts follow the ECU software version; VIN is a coarser fallback; live-data
/// agreement is the last resort when neither can be read. Nothing is ever
/// applied on the grounds that it is the only profile available — a plausible
/// wrong number is the failure this design exists to prevent.
public enum ProfileResolver {

    public enum Method: String, Equatable {
        case calibration
        case vin
        case agreement
        /// Development override, never reachable from the interface.
        case override
        case none
    }

    public struct Resolution: Equatable {
        public let profileID: String?
        public let method: Method
        /// Why this answer, in a form that can go into a session log.
        public let reason: String
        /// Candidates that tied, when the outcome is ambiguity rather than
        /// absence.
        public let ambiguousIDs: [String]

        public init(profileID: String?, method: Method, reason: String,
                    ambiguousIDs: [String] = []) {
            self.profileID = profileID
            self.method = method
            self.reason = reason
            self.ambiguousIDs = ambiguousIDs
        }

        public var isResolved: Bool { profileID != nil }

        public static func unresolved(_ reason: String, ambiguous: [String] = []) -> Resolution {
            Resolution(profileID: nil, method: .none, reason: reason,
                       ambiguousIDs: ambiguous.sorted())
        }
    }

    /// Two profiles scoring this close are not separable on the evidence.
    public static let scoreTieMargin = 0.05

    public static func resolve(
        candidates: [VehicleProfile],
        identity: VehicleIdentity = VehicleIdentity(),
        manufacturerAvailable: Bool,
        assessments: [ProfileAssessment] = []
    ) -> Resolution {
        let specifics = candidates.filter { $0.manufacturer != "Generic" }
        guard !specifics.isEmpty else {
            return .unresolved("No vehicle profiles are bundled.")
        }

        // 1. Calibration ID: exact match on the ECU software version.
        if let calibration = identity.calibrationID, !calibration.isEmpty {
            let matches = specifics.filter { $0.calibrationIDs?.contains(calibration) == true }
            if matches.count == 1 {
                return Resolution(profileID: matches[0].id, method: .calibration,
                                  reason: "Calibration \(calibration) matches this profile.")
            }
            if matches.count > 1 {
                if let winner = uniqueBest(matches.map(\.id), assessments) {
                    return Resolution(profileID: winner, method: .calibration,
                                      reason: "Calibration \(calibration) matches several profiles; live data separated them.")
                }
                return .unresolved("Calibration \(calibration) matches several profiles equally.",
                                   ambiguous: matches.map(\.id))
            }
        }

        // 2. VIN prefix. The longest matching prefix wins, so a model-specific
        //    prefix beats a shared manufacturer one.
        if let vin = identity.vin, !vin.isEmpty {
            let matches: [(id: String, length: Int)] = specifics.compactMap { profile in
                guard let longest = profile.vinPrefixes?
                    .filter({ !$0.isEmpty && vin.hasPrefix($0) })
                    .map(\.count).max()
                else { return nil }
                return (profile.id, longest)
            }
            if matches.count == 1 {
                return Resolution(profileID: matches[0].id, method: .vin,
                                  reason: "VIN \(vin.prefix(9)) matches this profile.")
            }
            if matches.count > 1 {
                let longest = matches.map(\.length).max() ?? 0
                let winners = matches.filter { $0.length == longest }.map(\.id)
                if winners.count == 1 {
                    return Resolution(profileID: winners[0], method: .vin,
                                      reason: "VIN \(vin.prefix(9)) matches several profiles; the longest prefix wins.")
                }
                if let winner = uniqueBest(winners, assessments) {
                    return Resolution(profileID: winner, method: .vin,
                                      reason: "VIN matches several profiles; live data separated them.")
                }
                return .unresolved("VIN \(vin.prefix(9)) matches several profiles equally.",
                                   ambiguous: winners)
            }
        }

        // 3. Live-data agreement, the only route that works with no identity.
        if manufacturerAvailable {
            let convincing = assessments.filter(\.convincing)
            if let winner = uniqueBest(convincing.map(\.profileID), assessments) {
                return Resolution(profileID: winner, method: .agreement,
                                  reason: "Manufacturer data agrees with the ECU's own readings.")
            }
            if convincing.count > 1 {
                return .unresolved("Manufacturer data agrees equally with several profiles.",
                                   ambiguous: convincing.map(\.profileID))
            }
            return .unresolved("The vehicle answers a manufacturer service, but its live data does not match any bundled profile.")
        }

        return .unresolved("The vehicle did not answer a manufacturer service.")
    }

    /// The highest-scoring convincing assessment within a candidate set, but
    /// only when it is clear of the runner-up.
    private static func uniqueBest(_ ids: [String], _ assessments: [ProfileAssessment]) -> String? {
        let candidates = assessments
            .filter { $0.convincing && ids.contains($0.profileID) }
            .sorted { $0.score > $1.score }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1, best.score - candidates[1].score <= scoreTieMargin {
            return nil
        }
        return best.profileID
    }
}
