/// Owns the single active instance of an asynchronous operation.
///
/// Reconnection is replacement-based: a new attempt may supersede an old one,
/// but the old task can finish later. Comparing the finishing task's token
/// prevents its cleanup from clearing or shutting down the replacement.
public struct SingleAttemptGate<Token: Equatable> {

    public private(set) var active: Token?

    public init() {}

    public var isIdle: Bool { active == nil }

    /// Returns false when another attempt already owns the gate.
    public mutating func begin(_ token: Token) -> Bool {
        guard active == nil else { return false }
        active = token
        return true
    }

    /// Clears the gate only if this is still the active attempt.
    @discardableResult
    public mutating func finish(_ token: Token) -> Bool {
        guard active == token else { return false }
        active = nil
        return true
    }

    /// Releases the gate regardless of generation, for a replacement attempt.
    @discardableResult
    public mutating func interrupt() -> Token? {
        defer { active = nil }
        return active
    }
}
