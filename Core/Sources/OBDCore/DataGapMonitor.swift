import Foundation

/// Detects stretches where the vehicle stops answering while the app is still
/// recording.
///
/// This matters for analysis: a silent period must be visible in the event
/// stream, otherwise the log looks like the engine simply did nothing for two
/// minutes. Ignition-off is the common cause, and it is not a fault.
///
/// A gap must also be closed for the right reason. "The car answered again" and
/// "the Bluetooth link dropped" are different events, and the second one must
/// never be recorded as the first: the log is used to work out why data stopped,
/// so a resumption that never happened makes it actively misleading.
public struct DataGapMonitor {

    public enum Transition: Equatable {
        case started(quietFor: TimeInterval)
        case ended(gapSeconds: TimeInterval, reason: GapEndReason)
    }

    /// How long without a successful read before a gap is declared.
    public let threshold: TimeInterval

    private var inGap = false
    private var gapStartedAt: Date?

    public init(threshold: TimeInterval = 10) {
        self.threshold = threshold
    }

    /// Feed the current time and the last successful sample time.
    /// Returns a transition only when the state changes, so repeated calls while
    /// a gap is open produce nothing.
    public mutating func update(now: Date, lastSampleAt: Date?) -> Transition? {
        guard let last = lastSampleAt else { return nil }
        let quietFor = now.timeIntervalSince(last)

        if !inGap, quietFor >= threshold {
            inGap = true
            gapStartedAt = last
            return .started(quietFor: quietFor)
        }

        if inGap, quietFor < threshold {
            inGap = false
            let duration = gapStartedAt.map { now.timeIntervalSince($0) } ?? quietFor
            gapStartedAt = nil
            // Data arrived: the only closure that may be called a resumption.
            return .ended(gapSeconds: duration, reason: .resumed)
        }

        return nil
    }

    public var isInGap: Bool { inGap }

    /// Called when recording stops or the link goes away: a still-open gap
    /// should be reported rather than silently closed, and the caller has to say
    /// why it ended.
    public mutating func finish(now: Date, reason: GapEndReason) -> Transition? {
        guard inGap else { return nil }
        inGap = false
        let duration = gapStartedAt.map { now.timeIntervalSince($0) } ?? 0
        gapStartedAt = nil
        return .ended(gapSeconds: duration, reason: reason)
    }
}

/// Why a data gap closed.
public enum GapEndReason: String, Equatable {
    /// A sample from the vehicle arrived. The only genuine resumption.
    case resumed
    /// The Bluetooth link dropped. The vehicle may or may not have been
    /// answering; nothing was recorded either way.
    case linkDown = "link_down"
    /// The polling loop stopped making progress and was reset.
    case stalled
    /// Recording ended while the gap was still open.
    case recordingStopped = "recording_stopped"
}
