import Foundation

/// Counts what a manufacturer sweep actually did.
///
/// The distinction that matters for anyone analysing logs: an identifier is
/// **attempted** whenever a request was sent, and **answered** only when a
/// parseable reply came back. A timeout and a malformed reply are both
/// attempts with no answer, and conflating them makes the log claim a car
/// supports fewer identifiers than it does — or more, if counts carry over.
public struct SweepAccountant {

    public struct Summary: Equatable {
        public let cycle: Int
        public let attempted: Int
        public let answered: Int
        /// Planned identifiers that were never requested in this cycle.
        public let missing: [UInt8]
    }

    private var attempted: Set<UInt8> = []
    private var answered: Set<UInt8> = []
    private var cycleCount = 0

    public init() {}

    /// Call *before* sending the request, so a timeout still counts.
    public mutating func recordAttempt(_ lid: UInt8) {
        attempted.insert(lid)
    }

    /// Call only when a parseable reply arrived.
    public mutating func recordAnswer(_ lid: UInt8) {
        answered.insert(lid)
    }

    /// Closes the cycle and resets the counters. Returns nil when nothing was
    /// attempted, which is what happens before the first full pass.
    public mutating func completeCycle(planned: [UInt8]) -> Summary? {
        guard !attempted.isEmpty else { return nil }
        cycleCount += 1

        let summary = Summary(
            cycle: cycleCount,
            attempted: attempted.count,
            answered: answered.count,
            missing: planned.filter { !attempted.contains($0) }
        )

        attempted.removeAll()
        answered.removeAll()
        return summary
    }

    public mutating func reset() {
        attempted.removeAll()
        answered.removeAll()
        cycleCount = 0
    }

    public var currentCycleAttempted: Int { attempted.count }
    public var currentCycleAnswered: Int { answered.count }
}
