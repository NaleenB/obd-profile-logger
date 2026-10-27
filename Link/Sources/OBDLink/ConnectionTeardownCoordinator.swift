import Foundation

/// Tracks CoreBluetooth teardown that has been requested but not yet observed.
///
/// A peripheral identifier is not a connection identity: reconnecting to the
/// same adapter reuses the same `CBPeripheral` and UUID. Until the previous
/// `didDisconnect`/`didFailToConnect` callback arrives, a replacement attempt
/// would receive the old callback and tear itself down. The coordinator both
/// records the barrier and lets the next connection wait for it.
final class ConnectionTeardownCoordinator: @unchecked Sendable {

    private struct Registry {
        private var pending: Set<UUID> = []

        mutating func begin(_ identifier: UUID) {
            pending.insert(identifier)
        }

        @discardableResult
        mutating func finish(_ identifier: UUID) -> Bool {
            pending.remove(identifier) != nil
        }

        func isPending(_ identifier: UUID) -> Bool {
            pending.contains(identifier)
        }

        var count: Int { pending.count }
    }

    private let lock = NSLock()
    private var registry = Registry()
    private var waiters: [UUID: [UUID: CheckedContinuation<Void, Error>]] = [:]

    func begin(_ identifier: UUID) {
        lock.lock()
        registry.begin(identifier)
        lock.unlock()
    }

    @discardableResult
    func finish(_ identifier: UUID) -> Bool {
        lock.lock()
        let wasPending = registry.finish(identifier)
        let waiting = waiters.removeValue(forKey: identifier) ?? [:]
        lock.unlock()

        if wasPending || !waiting.isEmpty {
            for waiter in waiting.values { waiter.resume() }
        }
        return wasPending
    }

    func isPending(_ identifier: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registry.isPending(identifier)
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registry.count
    }

    /// Waits until CoreBluetooth reports the previous connection closed.
    ///
    /// A timeout is an error rather than permission to continue: putting a new
    /// connection on the same peripheral while the old callback is still
    /// outstanding is exactly the race this barrier exists to prevent.
    func wait(for identifier: UUID, timeout: TimeInterval) async throws {
        guard isPending(identifier) else { return }

        let waiterID = UUID()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            guard registry.isPending(identifier) else {
                lock.unlock()
                cont.resume()
                return
            }
            waiters[identifier, default: [:]][waiterID] = cont
            lock.unlock()

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeout(identifier, waiterID: waiterID)
            }
        }
    }

    private func timeout(_ identifier: UUID, waiterID: UUID) {
        lock.lock()
        let waiter = waiters[identifier]?.removeValue(forKey: waiterID)
        if waiters[identifier]?.isEmpty == true {
            waiters[identifier] = nil
        }
        lock.unlock()
        waiter?.resume(throwing: BLEError.teardownTimedOut)
    }
}
