/// Tracks one profile sweep across connections.
///
/// The order of operations is the contract:
///
/// - `next()` chooses an identifier but records nothing.
/// - `requestSent(_:)` is called immediately before the `21xx` request; from
///   there a timeout is still an attempt.
/// - `finished(_:answered:)` is called only when that request reached a terminal
///   outcome, and closes the cycle when it was the last identifier of the pass.
///
/// A connection lost between `next()` and `requestSent(_:)` therefore leaves the
/// identifier unattempted instead of counting a request that was never sent, and
/// a lost connection during the request does not close a cycle without an
/// outcome.
public struct SweepPass {

    public struct Step: Equatable {
        public let lid: UInt8
        /// True when this identifier is the last of the current pass.
        public let isCycleEnd: Bool

        public init(lid: UInt8, isCycleEnd: Bool) {
            self.lid = lid
            self.isCycleEnd = isCycleEnd
        }
    }

    public let planned: [UInt8]

    private var index = 0
    private var current: Step?
    private var accountant = SweepAccountant()

    public init(planned: [UInt8]) {
        self.planned = planned
    }

    /// The next identifier to request, wrapping to a new pass after the last.
    public mutating func next() -> Step? {
        guard !planned.isEmpty else { return nil }
        current = nil

        let step = Step(lid: planned[index], isCycleEnd: index == planned.count - 1)
        index = step.isCycleEnd ? 0 : index + 1
        current = step
        return step
    }

    /// Call immediately before sending the identifier's `21xx` request.
    public mutating func requestSent(_ lid: UInt8) {
        guard current?.lid == lid else { return }
        accountant.recordAttempt(lid)
    }

    /// Call when the request produced a reply or timed out. A malformed reply is
    /// an attempt without an answer, so `answered` is false but the cycle can
    /// still close.
    public mutating func finished(_ lid: UInt8, answered: Bool) -> SweepAccountant.Summary? {
        guard let step = current, step.lid == lid else { return nil }
        current = nil
        if answered { accountant.recordAnswer(lid) }
        guard step.isCycleEnd else { return nil }
        return accountant.completeCycle(planned: planned)
    }

    /// The selected identifier never reached a terminal outcome because the
    /// connection was superseded. It remains unattempted unless `requestSent`
    /// had already run; either way this pass does not close here.
    public mutating func abandon() {
        current = nil
    }
}
