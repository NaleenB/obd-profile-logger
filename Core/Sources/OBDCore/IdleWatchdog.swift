import Foundation

/// Decides when a connected adapter should be dropped because the vehicle has
/// gone quiet.
///
/// "Idle" means **no successful samples**, not "the user is not touching the
/// app" — a car being driven produces samples continuously, so a drive never
/// times out. The common case this handles is the ignition being switched off
/// and the session left running.
public struct IdleWatchdog {

    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 600) {
        self.timeout = timeout
    }

    /// - Parameters:
    ///   - lastActivity: time of the most recent successful sample, if any.
    ///   - connectedAt: when the link was established, used before any sample
    ///     has arrived (a car that never answers should still time out).
    public func shouldDisconnect(now: Date, lastActivity: Date?, connectedAt: Date) -> Bool {
        let reference = lastActivity ?? connectedAt
        return now.timeIntervalSince(reference) >= timeout
    }

    /// Remaining time before the link is dropped, for display.
    public func remaining(now: Date, lastActivity: Date?, connectedAt: Date) -> TimeInterval {
        let reference = lastActivity ?? connectedAt
        return max(0, timeout - now.timeIntervalSince(reference))
    }
}
