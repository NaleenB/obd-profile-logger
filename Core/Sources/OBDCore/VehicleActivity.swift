import Foundation

/// Chooses the timestamps that represent vehicle activity.
///
/// `readings.lastUpdate` is cleared when a link drops so the UI cannot present
/// stale values. `lastSampleAt` deliberately survives that teardown, because the
/// car may still have been answering a moment earlier. Both the silence notice
/// and the idle watchdog must make the same choice; using the original
/// connection time after a reconnect made a short outage look like a long one.
public enum VehicleActivity {

    /// The last genuine answer, if one exists.
    ///
    /// The newer of the two wins. They normally move together, but a wake probe
    /// can prove the car answered without producing a displayable value, and a
    /// stale `lastUpdate` must not keep the loop in quiet mode.
    public static func lastAnswer(lastUpdate: Date?, lastSampleAt: Date?) -> Date? {
        switch (lastUpdate, lastSampleAt) {
        case let (update?, sample?): return max(update, sample)
        case let (update?, nil): return update
        case let (nil, sample?): return sample
        case (nil, nil): return nil
        }
    }

    /// The reference for "has the car gone quiet?".
    ///
    /// `connectedAt` is only a fallback before the first answer of a link. A
    /// preserved `lastSampleAt` must win over it after a reconnect.
    public static func silenceReference(
        lastUpdate: Date?,
        lastSampleAt: Date?,
        connectedAt: Date?
    ) -> Date? {
        lastAnswer(lastUpdate: lastUpdate, lastSampleAt: lastSampleAt) ?? connectedAt
    }
}
