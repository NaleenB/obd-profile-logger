/// What a pass over the mode-`01` supported-PID bitmaps actually established.
///
/// A bitmap is authoritative only for its own range. When one never answers,
/// the range it covers is *unknown*, not unsupported, and the two must not be
/// conflated: on 27 Oct 2026 the engine ECU woke part-way through the connect
/// probe, only the `0x40` bitmap parsed, and reducing that to a PID count
/// filtered a 28-PID car down to a single dashboard tile for the whole drive.
public struct PIDDiscovery: Equatable {

    /// Bitmaps, by their own PID, that answered.
    public private(set) var answeredBases: Set<UInt8> = []
    /// Every PID those bitmaps advertised.
    public private(set) var supportedPIDs: Set<UInt8> = []

    public init() {}

    /// The bitmap covering `pid`: `0x00` covers `01`-`20`, `0x20` covers
    /// `21`-`40`, and so on.
    public static func base(for pid: UInt8) -> UInt8 {
        guard pid > 0 else { return 0 }
        return UInt8((Int(pid) - 1) / 0x20 * 0x20)
    }

    public mutating func record(base: UInt8, pids: Set<UInt8>) {
        answeredBases.insert(base)
        supportedPIDs.formUnion(pids)
    }

    /// True when the first bitmap answered. Without it nothing is known about
    /// any range, so no filtering may be justified by this pass.
    public var isRooted: Bool { answeredBases.contains(0x00) }

    /// The highest bitmap whose range is known, treating a gap as the end of
    /// what can be judged.
    public var lastContiguousBase: UInt8? {
        guard isRooted else { return nil }
        var base: UInt8 = 0x00
        while base < 0xE0, answeredBases.contains(base &+ 0x20) {
            base = base &+ 0x20
        }
        return base
    }

    /// The bitmap the ECU declared but never answered. At most one, because
    /// probing stops at the first gap: without `0x20` there is no way to learn
    /// whether `0x40` exists.
    public var unansweredBases: Set<UInt8> {
        guard let last = lastContiguousBase else { return [] }
        let next = last &+ 0x20
        guard next <= (PIDCapabilities.probePIDs.last ?? 0x60),
              supportedPIDs.contains(next)
        else { return [] }
        return [next]
    }

    /// True when the last answered bitmap declared no successor, so nothing
    /// above its range exists and nothing earlier is missing.
    public var chainEnded: Bool { isRooted && unansweredBases.isEmpty }

    /// True while asking again could change the answer — the root is missing,
    /// or a declared bitmap never replied.
    public var needsRetry: Bool { !chainEnded }

    /// Whether `pid`'s range is judged by this pass at all.
    public func isKnown(_ pid: UInt8) -> Bool {
        guard let last = lastContiguousBase else { return false }
        return Self.base(for: pid) <= last || chainEnded
    }

    /// Whether a signal should be polled. Only a PID known to be absent is
    /// dropped; a PID in an unanswered range is kept, because a bitmap that did
    /// not reply is not evidence that the parameter is unsupported.
    public func shouldPoll(_ pid: UInt8) -> Bool {
        isKnown(pid) ? supportedPIDs.contains(pid) : true
    }
}
