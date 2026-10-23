import Foundation

/// Monotonic time source. Wall-clock changes must never move session time
/// backwards, so elapsed time comes from an uptime counter.
public protocol MonotonicClock {
    /// Milliseconds since the clock's origin. Never decreases.
    func nowMs() -> Int
}

public struct UptimeClock: MonotonicClock {
    private let origin: DispatchTime

    public init() {
        origin = .now()
    }

    public func nowMs() -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- origin.uptimeNanoseconds) / 1_000_000)
    }
}

/// Deterministic clock for tests.
public final class ManualClock: MonotonicClock {
    private var current: Int

    public init(start: Int = 0) {
        current = start
    }

    public func nowMs() -> Int { current }

    public func advance(by ms: Int) { current += ms }

    public func set(_ ms: Int) { current = ms }
}

/// Wall-clock timestamps for correlation only. Never used for ordering.
public enum WallClock {
    // ISO8601DateFormatter is not Sendable but is safe for concurrent reads;
    // usage here is formatting only.
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func iso(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}
