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
    /// A drop this far below the pre-crank baseline counts as cranking even if
    /// the absolute floor is not reached. Crank dips on this car bottom out
    /// around 10.6-10.9 V, above the absolute threshold.
    public static let crankDropVolts = 0.4
    public static let recoveryVolts = 13.5

    private var samples: [VoltageSample] = []
    private var phase: BatteryPhase = .unknown
    private(set) public var observedCrank = false
    private var preCrankVolts: Double?
    private var preCrankBaseline: Double?
    private var chargingRecovered = false
    private var peakRunningVolts: Double = 0
    private var engineStopped = false
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

        let next = classify(sample)

        // Once the engine has been seen running, an RPM below idle means it was
        // switched off. Latching "running" is right for the phase, but charging
        // voltage must stop being collected or a shutdown reading is graded as
        // an alternator fault.
        if phase == .running, let rpm = sample.rpm, rpm < Self.runningRpm {
            engineStopped = true
        }

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
            preCrankBaseline = max(preCrankBaseline ?? sample.volts, sample.volts)

        case .cranking:
            crankMinimum = min(crankMinimum ?? sample.volts, sample.volts)
            if crankStartMs == nil { crankStartMs = sample.atMs }

        case .running:
            if runningStartMs == nil {
                runningStartMs = sample.atMs
                preCrankVolts = preCrankVolts ?? previousVoltsBefore(sample.atMs)
            }
            if engineStopped { return }
            if let start = runningStartMs, sample.atMs - start > 1_000 {
                peakRunningVolts = max(peakRunningVolts, sample.volts)
                if sample.volts >= Self.recoveryVolts {
                    if recoveryMs == nil { recoveryMs = sample.atMs - start }
                    chargingRecovered = true
                }
                // Only count samples once the alternator has taken over, or
                // after ten seconds if it never does — in that case the low
                // reading is the finding.
                if chargingRecovered || sample.atMs - start > 10_000 {
                    runningVoltages.append(sample.volts)
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
        // Relative drop: a battery that only sags to 10.9 V still cranked.
        if let baseline = preCrankBaseline, baseline - sample.volts >= Self.crankDropVolts {
            return .cranking
        }
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

            // Vehicles with a battery current sensor deliberately drop to float
            // once the battery accepts little current. Settling below the band
            // after having demonstrably charged is that behaviour, not a fault.
            let settledAfterCharging = chargingRecovered && peakRunningVolts >= Self.recoveryVolts

            let severity: Severity
            let message: String
            if band.contains(running) {
                severity = .ok
                message = String(format: "%.2f V while running — charging normally", running)
            } else if settledAfterCharging {
                severity = .ok
                message = String(format: "reached %.1f V then settled at %.2f V — consistent with a battery that is already full (smart charging)",
                                 peakRunningVolts, running)
            } else {
                severity = .watch
                message = String(format: "%.2f V while running and never above 13.5 V — check the alternator or belt, this is not a battery fault", running)
            }

            findings.append(Finding(
                key: "running_voltage",
                label: "Charging voltage",
                severity: severity,
                message: message,
                source: .heuristic("13.8-14.5 V, unless the system demonstrably charges then floats"),
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
    /// True once a plausible charging voltage has been seen, or enough time has
    /// passed that the absence of one is itself the finding.
    public var chargingSettled: Bool {
        guard let start = runningStartMs else { return false }
        // A stopped engine produces no more charging data, so report what we
        // have rather than waiting forever.
        if chargingRecovered || engineStopped { return true }
        return samples.last.map { $0.atMs - start > 10_000 } ?? false
    }

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

public extension BatteryReport {

    /// Flattened for `events.ndjson`. Kept here so the formatting is tested
    /// rather than living in a view.
    var eventDetails: [String: String] {
        var details: [String: String] = [
            "phase": phaseReached.rawValue,
            "startObserved": startObserved ? "true" : "false",
            "verdict": verdict.rawValue,
            "samples": String(sampleCount)
        ]
        if let value = preCrankVolts { details["preCrankVolts"] = String(format: "%.2f", value) }
        if let value = crankMinimumVolts { details["crankMinimumVolts"] = String(format: "%.2f", value) }
        if let value = runningVolts { details["runningVolts"] = String(format: "%.2f", value) }
        if let value = crankDurationMs { details["crankDurationMs"] = String(value) }
        if let value = recoveryMs { details["recoveryMs"] = String(value) }
        for finding in findings {
            details["finding.\(finding.key)"] = finding.severity.rawValue
        }
        return details
    }
}
