/// Ownership of the shared connection transport between awaited operations.
///
/// Swift cancellation is cooperative, and BLE discovery/connection calls can
/// return successfully after their task was cancelled. A superseded attempt
/// must therefore stop at the next checkpoint instead of starting a fallback
/// scan or connecting to its result. Only the attempt that still owns the
/// transport may shut it down: a newer attempt owns the replacement, and a user
/// disconnect has already closed it.
public struct ConnectionLease<Token: Equatable> {

    public enum Checkpoint: Equatable {
        case proceed
        /// The attempt must stop. `shutdownTransport` is true when it is still
        /// the transport owner and may have opened a connection that nobody
        /// else will close.
        case aborted(shutdownTransport: Bool)
    }

    private var owner: Token?

    public init() {}

    /// Claims the transport for a new attempt, superseding any previous owner.
    public mutating func claim(_ token: Token) {
        owner = token
    }

    /// Releases ownership when the caller has already shut the transport down.
    public mutating func release() {
        owner = nil
    }

    /// Decides whether an attempt may continue after an awaited operation.
    ///
    /// A stale attempt that still owns the transport is responsible for closing
    /// it, because no replacement will. A stale attempt that no longer owns it
    /// must leave the newer connection alone.
    public mutating func checkpoint(_ token: Token, isCurrent: Bool) -> Checkpoint {
        if isCurrent { return .proceed }
        guard owner == token else { return .aborted(shutdownTransport: false) }
        owner = nil
        return .aborted(shutdownTransport: true)
    }
}
