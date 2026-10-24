import Foundation

/// What one candidate profile claims, scored against what the car reports.
///
/// A profile is only applied when a *required* discriminator agrees — engine
/// speed, usually — because it changes fast enough that a wrong byte cannot
/// track it. Coolant and plausibility ranges corroborate but never decide.
public struct ProfileAssessment: Equatable {
    public let profileID: String
    public let score: Double
    public let convincing: Bool
    /// Set when a required discriminator was actually measured and disagreed.
    /// Used to report a profile that matched by calibration but whose layout
    /// does not behave as it says.
    public let contradicted: Bool
    /// Evidence lines for the session log, so a mismatch can be diagnosed from
    /// the recording rather than guessed at.
    public let evidence: [String]

    public init(profileID: String, score: Double, convincing: Bool,
                contradicted: Bool, evidence: [String]) {
        self.profileID = profileID
        self.score = score
        self.convincing = convincing
        self.contradicted = contradicted
        self.evidence = evidence
    }
}

public enum ProfileMatcher {

    /// Below this the profile's layout may be partially right, which is worse
    /// than being obviously wrong.
    public static let minimumScore = 0.5
    /// A miss within this multiple of the tolerance earns partial credit but
    /// can never satisfy a requirement.
    public static let nearMissFactor = 3.0
    public static let nearMissCredit = 0.35

    /// True when every required discriminator has both a decoded value and a
    /// reference above its floor, so an assessment would mean something. Used to
    /// tell "no contradiction found" from "not enough evidence to look".
    public static func hasRequiredEvidence(
        profile: VehicleProfile,
        manufacturer: [Int: Double],
        standard: [UInt8: Double]
    ) -> Bool {
        guard let spec = profile.identity else { return false }
        let required = spec.discriminators.filter { $0.required == true }
        guard !required.isEmpty else { return false }
        return required.allSatisfy { rule in
            guard let pid = rule.pidValue,
                  let reference = standard[pid],
                  reference >= (rule.minimumStandard ?? 0),
                  manufacturer[rule.itemNumber] != nil
            else { return false }
            return true
        }
    }

    /// - Parameter manufacturer: item number to value, decoded with *this*
    ///   profile. A wrong layout produces plausible-looking numbers here, which
    ///   is exactly why they are checked against independent values.
    /// - Parameter standard: PID to value from mode `01`.
    public static func assess(
        profile: VehicleProfile,
        manufacturer: [Int: Double],
        standard: [UInt8: Double]
    ) -> ProfileAssessment {
        guard let spec = profile.identity else {
            return ProfileAssessment(profileID: profile.id, score: 0,
                                     convincing: false, contradicted: false, evidence: [])
        }

        let requiredCount = spec.discriminators.filter { $0.required == true }.count
        var requiredSatisfied = requiredCount > 0
        var contradicted = false
        var score = 0.0
        var evidence: [String] = []

        for rule in spec.discriminators {
            let required = rule.required == true

            guard let pid = rule.pidValue, let reference = standard[pid] else {
                // A missing corroborating value must not veto the required test.
                if required { requiredSatisfied = false }
                evidence.append("item \(rule.itemNumber): no reference for PID \(rule.sameAsPID)")
                continue
            }
            if let floor = rule.minimumStandard, reference < floor {
                if required { requiredSatisfied = false }
                evidence.append(String(format: "item %d: %.0f is below the %.0f comparison floor",
                                       rule.itemNumber, reference, floor))
                continue
            }
            guard let decoded = manufacturer[rule.itemNumber] else {
                // The block may not have answered on this pass.
                if required { requiredSatisfied = false }
                evidence.append("item \(rule.itemNumber): no answer")
                continue
            }

            let difference = abs(decoded - reference)
            if difference <= rule.tolerance {
                score += rule.weight
                evidence.append(String(format: "item %d agrees: %.1f vs %.1f", rule.itemNumber, decoded, reference))
            } else if difference <= rule.tolerance * nearMissFactor {
                score += rule.weight * nearMissCredit
                if required {
                    requiredSatisfied = false
                    contradicted = true
                }
                evidence.append(String(format: "item %d is near: %.1f vs %.1f", rule.itemNumber, decoded, reference))
            } else {
                if required {
                    requiredSatisfied = false
                    contradicted = true
                }
                evidence.append(String(format: "item %d disagrees: %.1f vs %.1f", rule.itemNumber, decoded, reference))
            }
        }

        for rule in spec.plausibility ?? [] {
            guard let decoded = manufacturer[rule.itemNumber] else { continue }
            if decoded >= rule.min && decoded <= rule.max {
                score += rule.weight
                evidence.append(String(format: "item %d plausible: %.0f", rule.itemNumber, decoded))
            } else {
                evidence.append(String(format: "item %d implausible: %.0f", rule.itemNumber, decoded))
            }
        }

        let convincing = requiredSatisfied && score >= minimumScore
        return ProfileAssessment(profileID: profile.id, score: score,
                                 convincing: convincing, contradicted: contradicted,
                                 evidence: evidence)
    }
}
