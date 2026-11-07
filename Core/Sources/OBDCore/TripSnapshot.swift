import Foundation

/// Field naming and the cached half of a `trip_snapshot` event.
///
/// The fresh snapshot at the start of a session and the cached one at the end
/// are meant to be compared field by field, so both go through the same
/// formatter here: a key that differs between them turns a present parameter
/// into an apparently missing one.
public enum TripSnapshot {

    /// The detail key a decoded parameter is stored under, e.g.
    /// `0A.target_a/f_comp_value1`.
    public static func key(lid: UInt8, name: String) -> String {
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "")
        return String(format: "%02X.%@", lid, slug)
    }

    /// The end-of-session snapshot, built from the live cache.
    ///
    /// Only the identifiers the profile declares for snapshotting are emitted.
    /// The cache also holds every other decoded `0x21` parameter, and the sweep
    /// reads those once per pass: dumping all of them recorded a parked car at
    /// 44 km/h and 1 375 rpm on session `20261104-164839-8C42`, from a `LID 01`
    /// read 65 s earlier. Engine state is not end-of-session state, so it is not
    /// written here; the samples above it still hold every observation.
    ///
    /// The remaining identifiers are slow-moving counters, but they are still
    /// cached, so the age of the oldest one is returned with them rather than
    /// implied. A sweep cycle on this car takes about 110 s.
    public static func cached(
        lids: [UInt8],
        parameters: [DecodedParameter],
        updatedAt: [String: Date],
        now: Date
    ) -> (details: [String: String], maxAgeSeconds: Double?) {
        let wanted = Set(lids)
        var details: [String: String] = [:]
        var oldest: TimeInterval?

        for parameter in parameters where wanted.contains(parameter.lid) {
            details[key(lid: parameter.lid, name: parameter.name)] =
                String(format: "%.2f", parameter.value)
            if let at = updatedAt[parameter.id] {
                oldest = max(oldest ?? 0, now.timeIntervalSince(at))
            }
        }
        return (details, oldest)
    }
}
