import Foundation

/// One voltage observation. Both signals are optional because the ECU cannot
/// always answer during a crank.
public struct VoltageSample: Equatable {
    public let atMs: Int
    public let volts: Double
    public let rpm: Double?

    public init(atMs: Int, volts: Double, rpm: Double? = nil) {
        self.atMs = atMs
        self.volts = volts
        self.rpm = rpm
    }
}

public enum BatteryPhase: String, Equatable {
    case unknown
    case ignitionOn
    case cranking
    case running
}

public struct BatteryReport {
    public let phaseReached: BatteryPhase
    /// True only when a cranking phase was actually observed. Monitoring that
    /// begins with the engine already running has no start event to grade.
    public let startObserved: Bool
    /// Last voltage seen before the crank began.
    public let preCrankVolts: Double?
    /// Lowest voltage observed while cranking. The number that matters.
    public let crankMinimumVolts: Double?
    public let crankDurationMs: Int?
    /// Typical charging voltage once the engine caught.
    public let runningVolts: Double?
    /// Time from engine catch to the alternator recovering the bus.
    public let recoveryMs: Int?
    public let sampleCount: Int
    public let findings: [Finding]

    /// A battery verdict requires a complete start event. Running-voltage
    /// observations are still reported, but they cannot clear or condemn a
    /// battery on their own.
    public var verdict: Severity {
        guard startObserved, phaseReached == .running else { return .insufficientData }
        return HealthEvaluator.worst(findings)
    }
}

/// Detects and grades a start event from a stream of voltage and RPM samples.
///
/// Stages, in order: ignition on → cranking → running. Crank detection combines
/// RPM with a voltage dip, because some ECUs report no RPM until the engine
/// syncs, and some report a little; either signal alone is unreliable.
public final class BatteryMonitor {

    public static let crankRpm = 60.0
    public static let runningRpm = 400.0
    public static let crankDipVolts = 10.6
    public static let recoveryVolts = 13.5

    private var samples: [VoltageSample] = []
    private var phase: BatteryPhase = .unknown
    private(set) public var observedCrank = false
    private var preCrankVolts: Double?
    private var crankMinimum: Double?
    private var crankStartMs: Int?
    private var runningStartMs: Int?
    private var recoveryMs: Int?
    private var runningVoltages: [Double] = []

    public init() {}

    public var currentPhase: BatteryPhase { phase }
    public var latestVolts: Double? { samples.last?.volts }

    public func ingest(_ sample: VoltageSample) {
        samples.append(sample)

        let previous = phase
        let next = classify(sample)

        // Record a start event only when a crank was actually seen, whether from
        // RPM or from the voltage dip fallback.
        if next == .cranking { observedCrank = true }

        // Latch: once the engine is running, a later dip is not a new crank.
        if next.rawRank >= phase.rawRank {
            phase = next
        }

        switch phase {
        case .ignitionOn:
            preCrankVolts = sample.volts

        case .cranking:
            crankMinimum = min(crankMinimum ?? sample.volts, sample.volts)
            if crankStartMs == nil { crankStartMs = sample.atMs }

        case .running:
            if runningStartMs == nil {
                runningStartMs = sample.atMs
                preCrankVolts = preCrankVolts ?? previousVoltsBefore(sample.atMs)
            }
            // Ignore the first second: that is the alternator spinning up, not
            // steady-state charging.
            if let start = runningStartMs, sample.atMs - start > 1_000 {
                runningVoltages.append(sample.volts)
                if recoveryMs == nil, sample.volts >= Self.recoveryVolts {
                    recoveryMs = sample.atMs - start
                }
            }

        case .unknown:
            break
        }
    }

    private func previousVoltsBefore(_ atMs: Int) -> Double? {
        samples.last(where: { $0.atMs < atMs })?.volts
    }

    private func classify(_ sample: VoltageSample) -> BatteryPhase {
        if let rpm = sample.rpm {
            if rpm >= Self.runningRpm { return .running }
            if rpm >= Self.crankRpm { return .cranking }
        }
        // No usable RPM: fall back to voltage shape.
        if phase == .running { return .running }
        // A bus already being charged means the engine is turning, even if the
        // ECU never reported RPM during the crank.
        if sample.volts >= Self.recoveryVolts { return .running }
        if sample.volts < Self.crankDipVolts { return .cranking }
        return .ignitionOn
    }

    public func report() -> BatteryReport {
        var findings: [Finding] = []

        if let pre = preCrankVolts {
            let low = pre < VehicleSpec.restingVoltsHealthy.lowerBound
            findings.append(Finding(
                key: "pre_crank_voltage",
                label: "Voltage before cranking",
                severity: low ? .watch : .ok,
                message: low
                    ? String(format: "%.1f V before cranking — low for a battery about to work", pre)
                    : String(format: "%.1f V before cranking", pre),
                source: .heuristic("12.2 V is the 50% state-of-charge point"),
                observed: pre,
                unit: "V"
            ))
        }

        if let crank = crankMinimum {
            let severity: Severity
            if crank >= VehicleSpec.crankMinimumHealthy {
                severity = .ok
            } else if crank >= VehicleSpec.crankMinimumFail {
                severity = .watch
            } else {
                severity = .suspect
            }
            findings.append(Finding(
                key: "crank_minimum",
                label: "Lowest voltage while cranking",
                severity: severity,
                message: String(format: "%.1f V during crank (healthy is above %.1f V, failing below %.1f V)",
                                crank, VehicleSpec.crankMinimumHealthy, VehicleSpec.crankMinimumFail),
                source: .heuristic("cranking should stay above 9.5 V; below 9.0 V indicates a failing battery"),
                observed: crank,
                unit: "V"
            ))
        }

        if let running = runningVolts() {
            let band = VehicleSpec.chargingVolts
            let severity: Severity = band.contains(running) ? .ok : .watch
            findings.append(Finding(
                key: "running_voltage",
                label: "Charging voltage",
                severity: severity,
                message: severity == .ok
                    ? String(format: "%.2f V while running — charging normally", running)
                    : String(format: "%.2f V while running — check the alternator or belt, this is not a battery fault", running),
                source: .heuristic("13.8-14.5 V with the engine running"),
                observed: running,
                unit: "V"
            ))
        }

        if !observedCrank {
            findings.append(Finding(
                key: "no_start_observed",
                label: "Start event",
                severity: .insufficientData,
                message: phase == .running
                    ? "Monitoring began with the engine already running, so no crank was measured. Restart with the engine off to grade the battery."
                    : "No crank followed by a running engine was observed.",
                source: .heuristic("a battery test requires a captured start"),
                observed: nil,
                unit: "V"
            ))
        }

        return BatteryReport(
            phaseReached: phase,
            startObserved: observedCrank,
            preCrankVolts: preCrankVolts,
            crankMinimumVolts: crankMinimum,
            crankDurationMs: {
                guard let start = crankStartMs, let run = runningStartMs else { return nil }
                return run - start
            }(),
            runningVolts: runningVolts(),
            recoveryMs: recoveryMs,
            sampleCount: samples.count,
            findings: findings
        )
    }

    /// Median of the settled running samples: robust against the odd bad read.
    private func runningVolts() -> Double? {
        guard !runningVoltages.isEmpty else { return nil }
        let sorted = runningVoltages.sorted()
        return sorted[sorted.count / 2]
    }
}

extension BatteryPhase {
    /// Ordering used to stop the monitor falling back to an earlier stage.
    var rawRank: Int {
        switch self {
        case .unknown: return 0
        case .ignitionOn: return 1
        case .cranking: return 2
        case .running: return 3
        }
    }
}
