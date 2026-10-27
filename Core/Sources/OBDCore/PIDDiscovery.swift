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
    /// Each answered bitmap, kept separately so an orphan reply cannot add PIDs
    /// outside the chain its predecessors declared.
    private var bitmaps: [UInt8: Set<UInt8>] = [:]

    public init() {}

    /// The bitmap covering `pid`: `0x00` covers `01`-`20`, `0x20` covers
    /// `21`-`40`, and so on.
    public static func base(for pid: UInt8) -> UInt8 {
        guard pid > 0 else { return 0 }
        return UInt8((Int(pid) - 1) / 0x20 * 0x20)
    }

    public mutating func record(base: UInt8, pids: Set<UInt8>) {
        answeredBases.insert(base)
        bitmaps[base] = pids
    }

    /// True when the first bitmap answered. Without it nothing is known about
    /// any range, so no filtering may be justified by this pass.
    public var isRooted: Bool { answeredBases.contains(0x00) }

    /// The highest bitmap whose range is known, treating a gap as the end of
    /// what can be judged.
    ///
    /// The chain has to be coherent as well as contiguous: a bitmap only counts
    /// when the previous one advertised it. Two modules answer a broadcast
    /// request on this car, and a late reply from the transmission must not
    /// lend authority to an engine range its own bitmap never declared.
    public var lastContiguousBase: UInt8? {
        guard isRooted else { return nil }
        var base: UInt8 = 0x00
        while base < 0xE0,
              bitmaps[base]?.contains(base &+ 0x20) == true,
              bitmaps[base &+ 0x20] != nil {
            base = base &+ 0x20
        }
        return base
    }

    /// Every PID advertised by the contiguous chain.
    ///
    /// An answer outside the chain is retained in `answeredBases` so a retry
    /// does not ask for it again, but its PIDs are not treated as supported.
    public var supportedPIDs: Set<UInt8> {
        guard isRooted, let last = lastContiguousBase else { return [] }
        var supported: Set<UInt8> = []
        var base: UInt8 = 0x00
        while true {
            supported.formUnion(bitmaps[base] ?? [])
            guard base < last else { break }
            base = base &+ 0x20
        }
        return supported
    }

    /// The bitmap the ECU declared but never answered. At most one, because
    /// probing stops at the first gap: without `0x20` there is no way to learn
    /// whether `0x40` exists.
    public var unansweredBases: Set<UInt8> {
        guard let last = lastContiguousBase, last < 0xE0,
              bitmaps[last]?.contains(last &+ 0x20) == true
        else { return [] }
        return [last &+ 0x20]
    }

    /// True when the last answered bitmap declared no successor, so nothing
    /// above its range exists and nothing earlier is missing.
    public var chainEnded: Bool { isRooted && unansweredBases.isEmpty }

    /// True while asking again could change the answer — the root is missing,
    /// or a declared bitmap never replied.
    public var needsRetry: Bool { !chainEnded }

    /// The next bitmap the probe should request, or nil when this pass is done.
    ///
    /// The decision belongs here rather than in the app: probing above a missing
    /// root learns nothing, and probing above an undeclared successor asks a
    /// compliant ECU for a range it has already said does not exist.
    public func nextProbe(_ bases: [UInt8] = PIDCapabilities.probePIDs) -> UInt8? {
        for base in bases {
            if answeredBases.contains(base) { continue }
            if base != 0x00, !isRooted { return nil }
            if isRooted, !supportedPIDs.contains(base) { return nil }
            return base
        }
        return nil
    }

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
