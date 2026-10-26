/// Whether a BLE connection actually finished setup.
///
/// The serial characteristic is resolved before notifications are subscribed,
/// and a failed or timed-out setup leaves that port reference behind. Treating
/// "port known" as "link established" made a failed connection look like an
/// established link dropping, which invalidated the reconnect loop that was
/// still retrying it.
public struct LinkReadiness {

    public private(set) var didResolvePort = false
    public private(set) var isEstablished = false

    public init() {}

    /// The serial characteristic was chosen; notification setup is still pending.
    public mutating func resolvePort() {
        didResolvePort = true
    }

    /// Notification subscription succeeded and the connection is usable.
    ///
    /// Ignored when no port was resolved, so a late callback cannot promote a
    /// connection that never reached that stage.
    public mutating func markEstablished() {
        guard didResolvePort else { return }
        isEstablished = true
    }

    /// A new connection attempt, a failure, or a teardown.
    public mutating func reset() {
        didResolvePort = false
        isEstablished = false
    }
}
