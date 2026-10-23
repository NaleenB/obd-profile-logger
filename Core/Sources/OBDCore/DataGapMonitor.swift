import Foundation

/// Detects stretches where the vehicle stops answering while the app is still
/// recording.
///
/// This matters for analysis: a silent period must be visible in the event
/// stream, otherwise the log looks like the engine simply did nothing for two
/// minutes. Ignition-off is the common cause, and it is not a fault.
public struct DataGapMonitor {

    public enum Transition: Equatable {
        case started(quietFor: TimeInterval)
        case ended(gapSeconds: TimeInterval)
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
            return .ended(gapSeconds: duration)
        }

        return nil
    }

    public var isInGap: Bool { inGap }

    /// Called when recording stops: a still-open gap should be reported rather
    /// than silently closing.
    public mutating func finish(now: Date) -> Transition? {
        guard inGap else { return nil }
        inGap = false
        let duration = gapStartedAt.map { now.timeIntervalSince($0) } ?? 0
        gapStartedAt = nil
        return .ended(gapSeconds: duration)
    }
}
