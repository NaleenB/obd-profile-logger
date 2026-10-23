import Foundation

/// Evidence that a profile's byte offsets actually describe this car.
///
/// Identity matching (VIN, calibration ID) is the preferred proof but can fail to
/// read. This is the fallback: decode a few manufacturer fields the profile knows
/// about and check them against values the car reports independently over
/// standard OBD. If the profile's layout were wrong, its "engine speed" would be a
/// random byte and would not agree with the ECU's own rpm reading.
public struct ProfileEvidence: Equatable {
    /// Engine speed decoded from the manufacturer block using the candidate profile.
    public let manufacturerRPM: Double?
    /// The same quantity from mode 01 PID 0x0C.
    public let standardRPM: Double?
    public let manufacturerCoolant: Double?
    public let standardCoolant: Double?
    public let odometerKm: Double?

    public init(
        manufacturerRPM: Double? = nil,
        standardRPM: Double? = nil,
        manufacturerCoolant: Double? = nil,
        standardCoolant: Double? = nil,
        odometerKm: Double? = nil
    ) {
        self.manufacturerRPM = manufacturerRPM
        self.standardRPM = standardRPM
        self.manufacturerCoolant = manufacturerCoolant
        self.standardCoolant = standardCoolant
        self.odometerKm = odometerKm
    }
}

public enum ProfileMatcher {

    /// 0...1. Agreement on engine speed dominates because it is a fast-changing
    /// signal: a wrong byte almost never lands within 50 rpm of the truth.
    public static func score(_ evidence: ProfileEvidence) -> Double {
        var score = 0.0

        if let a = evidence.manufacturerRPM, let b = evidence.standardRPM, b > 0 {
            let difference = abs(a - b)
            if difference <= 50 { score += 0.5 }
            else if difference <= 150 { score += 0.25 }
        }

        if let a = evidence.manufacturerCoolant, let b = evidence.standardCoolant {
            let difference = abs(a - b)
            if difference <= 5 { score += 0.3 }
            else if difference <= 10 { score += 0.15 }
        }

        if let odometer = evidence.odometerKm, odometer >= 100, odometer <= 2_000_000 {
            score += 0.2
        }

        return min(score, 1.0)
    }

    /// Requires engine-speed agreement specifically. Coolant alone is a slow
    /// signal and two unrelated bytes can easily land within a few degrees.
    public static func isConvincing(_ evidence: ProfileEvidence) -> Bool {
        guard let a = evidence.manufacturerRPM, let b = evidence.standardRPM, b > 0 else {
            return false
        }
        return abs(a - b) <= 50 && score(evidence) >= 0.5
    }
}
