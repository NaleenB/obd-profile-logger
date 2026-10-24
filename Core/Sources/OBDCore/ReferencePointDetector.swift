import Foundation

/// Captures a reference-point differential pressure: a steady condition that can
/// be compared between sessions and across months.
///
/// This exists because a peak Δp is not comparable — it depends on how hard the
/// car happened to be driven. A stable 2,000 rpm at ~60 g/s on flat road gives a
/// number where the only variable left is how loaded the filter is.
///
/// Both bands are deliberately tight. A wide window would produce values that
/// look comparable and are not, which is worse than recording nothing.
///
/// Not yet wired into the app or Probe; this is groundwork for the baseline
/// learning feature. Its tests validate this detector, not the shipped dashboard.
public struct ReferencePointDetector {

    public struct Reference: Equatable {
        public let rpm: Double
        public let mafGramsPerSecond: Double
        public let deltaPressureKPa: Double
        public let at: Date
    }

    private struct Sample {
        let at: Date
        let rpm: Double
        let maf: Double
        let dp: Double
    }

    public let targetRPM: Double
    public let rpmTolerance: Double
    public let targetMAF: Double
    public let mafTolerance: Double
    public let window: TimeInterval
    public let cooldown: TimeInterval
    public let minimumSamples: Int

    private var buffer: [Sample] = []
    private var lastEmittedAt: Date?

    public init(
        targetRPM: Double = 2_000,
        rpmTolerance: Double = 100,
        targetMAF: Double = 60,
        mafTolerance: Double = 10,
        window: TimeInterval = 10,
        cooldown: TimeInterval = 60,
        minimumSamples: Int = 5
    ) {
        self.targetRPM = targetRPM
        self.rpmTolerance = rpmTolerance
        self.targetMAF = targetMAF
        self.mafTolerance = mafTolerance
        self.window = window
        self.cooldown = cooldown
        self.minimumSamples = minimumSamples
    }

    /// Feed one observation. Returns a reference the first time a stable window
    /// qualifies, then suppresses further ones for `cooldown`.
    public mutating func ingest(at date: Date, rpm: Double?, maf: Double?, dp: Double) -> Reference? {
        guard let rpm, let maf, rpm > 0, maf > 0 else {
            buffer.removeAll()
            return nil
        }

        buffer.append(Sample(at: date, rpm: rpm, maf: maf, dp: dp))
        // Hoisted: reading a self property inside a mutating call's closure is an
        // overlapping access.
        let windowSeconds = window
        let cutoff = date
        buffer.removeAll { cutoff.timeIntervalSince($0.at) > windowSeconds }

        guard buffer.count >= minimumSamples else { return nil }
        // Counting samples is not enough: they must actually span the window, or
        // a burst of fast polls would qualify a two-second glimpse.
        guard let first = buffer.first, let last = buffer.last,
              last.at.timeIntervalSince(first.at) >= window * 0.9
        else { return nil }

        let withinBands = buffer.allSatisfy {
            abs($0.rpm - targetRPM) <= rpmTolerance && abs($0.maf - targetMAF) <= mafTolerance
        }
        guard withinBands else { return nil }

        if let last = lastEmittedAt, date.timeIntervalSince(last) < cooldown { return nil }

        // Compute from the window before clearing it.
        let reference = Reference(
            rpm: median(buffer.map(\.rpm)).rounded(),
            mafGramsPerSecond: median(buffer.map(\.maf)),
            deltaPressureKPa: median(buffer.map(\.dp)),
            at: date
        )
        lastEmittedAt = date
        buffer.removeAll()
        return reference
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
