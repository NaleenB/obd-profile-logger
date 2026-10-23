import Foundation

/// Decides whether a DTC scan is worth writing to the event stream.
///
/// Deduplicates within a session and **must be reset when a new session starts**,
/// otherwise a session whose codes match the previous one writes no snapshot at
/// all and its diagnostic history is silently empty.
public struct DTCSnapshotGate {

    private var lastSignature: String?

    public init() {}

    /// True the first time a signature is seen, false while it repeats.
    public mutating func shouldEmit(_ signature: String) -> Bool {
        if signature == lastSignature { return false }
        lastSignature = signature
        return true
    }

    public mutating func reset() {
        lastSignature = nil
    }

    public var currentSignature: String? { lastSignature }
}

/// The live values shown on the dashboard.
///
/// Kept as one value type so clearing is a single operation that cannot forget a
/// field. Holding these in separate properties is how stale readings survive a
/// disconnect and look current.
public struct LiveReadings: Equatable {

    public private(set) var values: [String: Double] = [:]
    public private(set) var manufacturer: [String: DecodedParameter] = [:]
    public private(set) var lastUpdate: Date?

    public init() {}

    public mutating func setStandard(pid: String, value: Double, at date: Date) {
        values[pid] = value
        lastUpdate = date
    }

    public mutating func setManufacturer(_ parameter: DecodedParameter, at date: Date) {
        manufacturer[parameter.id] = parameter
        lastUpdate = date
    }

    /// Everything goes: values, manufacturer parameters and the timestamp that
    /// would otherwise make them look fresh.
    public mutating func clear() {
        values.removeAll()
        manufacturer.removeAll()
        lastUpdate = nil
    }

    /// Drops decoded values only, keeping standard PIDs. Used when the decoding
    /// profile changes mid-session and old values would be wrong.
    public mutating func clearManufacturer() {
        manufacturer.removeAll()
    }

    public var isEmpty: Bool {
        values.isEmpty && manufacturer.isEmpty && lastUpdate == nil
    }

    /// True when nothing has arrived for `interval`, so the UI can say so rather
    /// than presenting old numbers as current.
    public func isStale(now: Date, after interval: TimeInterval) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > interval
    }
}
