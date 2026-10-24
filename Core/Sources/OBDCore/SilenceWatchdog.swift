import Foundation

/// Decides what the poll loop should do when the car — not the adapter — stops
/// answering.
///
/// The link can be perfectly healthy while the vehicle says nothing: with the
/// ignition off the ECU sleeps and every request comes back "NO DATA" in a few
/// hundred milliseconds. That is not a fault and not a frozen app, but it used
/// to look like one, because the screen kept showing the last values under a
/// "Connected" status with no indication that nothing had arrived for minutes.
///
/// The same state is where the loop should stop asking the whole signal list:
/// each request while the car is asleep is a request that cannot be answered.
public struct SilenceWatchdog {

    /// Quiet for this long is worth telling the user about.
    public let noticeAfter: TimeInterval
    /// Quiet for this long means the full signal list is a waste of requests.
    public let quietAfter: TimeInterval
    /// How often quiet mode asks whether the car has woken.
    public let quietInterval: TimeInterval

    public init(
        noticeAfter: TimeInterval = 5,
        quietAfter: TimeInterval = 15,
        quietInterval: TimeInterval = 3
    ) {
        self.noticeAfter = noticeAfter
        self.quietAfter = quietAfter
        self.quietInterval = quietInterval
    }

    /// Seconds since the car last said anything.
    ///
    /// `reference` is the last successful sample, or the time the link was
    /// established when nothing has arrived yet: a car that has never answered
    /// is still not answering. Nil means the link is not established, so there
    /// is nothing to judge.
    public func quietFor(now: Date, reference: Date?) -> TimeInterval? {
        guard let reference else { return nil }
        return max(0, now.timeIntervalSince(reference))
    }

    public func isNoticeable(now: Date, reference: Date?) -> Bool {
        guard let quiet = quietFor(now: now, reference: reference) else { return false }
        return quiet >= noticeAfter
    }

    /// True when the full cycle would only produce silence.
    public func shouldPollQuietly(now: Date, reference: Date?) -> Bool {
        guard let quiet = quietFor(now: now, reference: reference) else { return false }
        return quiet >= quietAfter
    }
}
