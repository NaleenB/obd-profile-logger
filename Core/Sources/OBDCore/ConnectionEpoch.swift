import Foundation

/// Identifies one connection or polling attempt.
///
/// Task cancellation alone is not enough around non-cancellable BLE and ELM
/// operations: an await can return successfully after the task was cancelled.
/// Callers capture a token and compare it before committing state, so work from
/// a superseded connection can never affect the current one.
public struct ConnectionEpoch: Equatable, Sendable {

    public struct Token: Equatable, Sendable {
        fileprivate let epochID: UUID
        public let generation: UInt64
    }

    private let epochID = UUID()
    public private(set) var generation: UInt64 = 0

    public init() {}

    public var currentToken: Token {
        Token(epochID: epochID, generation: generation)
    }

    /// Invalidates every previously issued token and returns the new one.
    @discardableResult
    public mutating func advance() -> Token {
        generation &+= 1
        return currentToken
    }

    public func isValid(_ token: Token) -> Bool {
        token.epochID == epochID && token.generation == generation
    }
}
