import Foundation

/// Detects when a DPF regeneration is happening, from the filter temperature.
///
/// Temperature rather than the ECU's own flag, because the flag lives in a block
/// that refreshes once per ~90 s sweep while the temperature is in the live block
/// sampled several times a second. A regeneration is a 10–20 minute event, so the
/// temperature is the reliable witness and the flag is a cross-check.
///
/// Hysteresis matters: a filter that has just finished sits well above idle
/// exhaust temperature for a while, and without a lower threshold the detector
/// would never close the event.
public struct RegenDetector {

    public enum Transition: Equatable {
        case started(tempC: Double)
        case ended(duration: TimeInterval, peakC: Double)
    }

    /// Above this, a regeneration is underway. Idle exhaust is well below.
    public let startC: Double
    /// Below this, and held for `endDwell`, the regeneration is over.
    public let endC: Double
    public let endDwell: TimeInterval

    public private(set) var isActive = false
    private var startedAt: Date?
    private var belowSince: Date?
    private var peak: Double = 0

    public init(startC: Double = 450, endC: Double = 300, endDwell: TimeInterval = 10) {
        self.startC = startC
        self.endC = endC
        self.endDwell = endDwell
    }

    public mutating func ingest(tempC: Double, at date: Date) -> Transition? {
        guard tempC.isFinite else { return nil }

        if !isActive {
            guard tempC >= startC else { return nil }
            isActive = true
            startedAt = date
            belowSince = nil
            peak = tempC
            return .started(tempC: tempC)
        }

        peak = max(peak, tempC)

        if tempC < endC {
            if belowSince == nil { belowSince = date }
            if let since = belowSince, date.timeIntervalSince(since) >= endDwell {
                let duration = startedAt.map { date.timeIntervalSince($0) } ?? 0
                isActive = false
                startedAt = nil
                belowSince = nil
                let peakValue = peak
                peak = 0
                return .ended(duration: duration, peakC: peakValue)
            }
        } else {
            // Rose again before the dwell elapsed: still regenerating.
            belowSince = nil
        }

        return nil
    }

    /// Closes an open event when a session ends, so a regeneration in progress is
    /// not silently dropped.
    public mutating func finish(at date: Date) -> Transition? {
        guard isActive else { return nil }
        let duration = startedAt.map { date.timeIntervalSince($0) } ?? 0
        isActive = false
        startedAt = nil
        belowSince = nil
        let peakValue = peak
        peak = 0
        return .ended(duration: duration, peakC: peakValue)
    }
}
