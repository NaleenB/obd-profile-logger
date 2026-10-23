import Foundation

/// A single value sampled from the ECU, in engineering units.
public struct Reading: Equatable {
    public let pid: UInt8
    public let value: Double
    public let unit: String
    public let atMs: Int

    public init(pid: UInt8, value: Double, unit: String, atMs: Int = 0) {
        self.pid = pid
        self.value = value
        self.unit = unit
        self.atMs = atMs
    }
}

/// Where a limit came from. This matters: a factory figure and a rule of thumb
/// must never be presented with the same confidence.
public enum LimitSource: Equatable {
    /// Mitsubishi service manual data-list item number.
    case serviceManual(item: Int)
    /// Derived by this project. Needs a baseline before it can be trusted.
    case heuristic(String)
}

public enum Severity: String, Equatable {
    case ok
    case watch
    case suspect
    case insufficientData
}

/// What the vehicle is doing, as asserted by the caller. Health checks need this:
/// the same voltage means different things with the engine running, the ignition
/// on, or after the car has been parked for an hour.
public enum PowerState: Equatable {
    case running
    case ignitionOn
    /// Engine off for `settledMinutes`.
    case resting(settledMinutes: Int)
}

/// The outcome of one check against one reading set.
public struct Finding: Equatable {
    public let key: String
    public let label: String
    public let severity: Severity
    public let message: String
    public let source: LimitSource
    /// Value that produced the verdict, if there was one.
    public let observed: Double?
    public let unit: String
}

/// A snapshot of a drive, in engineering units keyed by PID.
///
/// Every observation keeps its timestamp. Checks must read values through
/// `fresh(_:)`, so a check can never silently combine values sampled minutes
/// apart, or reuse a value from a poll that has since failed. The historical
/// stream belongs in the recorder, not here.
public struct ReadingSet {

    public struct Sample: Equatable {
        public let value: Double
        public let unit: String
        public let atMs: Int

        public init(value: Double, unit: String, atMs: Int) {
            self.value = value
            self.unit = unit
            self.atMs = atMs
        }
    }

    public private(set) var samples: [UInt8: Sample] = [:]
    public private(set) var runTimeSeconds: Double?

    /// The instant this set is evaluated against, on the same monotonic clock
    /// as each sample's `atMs`.
    public var referenceMs: Int

    public init(referenceMs: Int = 0) {
        self.referenceMs = referenceMs
    }

    public init(readings: [Reading], runTimeSeconds: Double? = nil, referenceMs: Int? = nil) {
        self.referenceMs = referenceMs ?? (readings.map(\.atMs).max() ?? 0)
        for reading in readings {
            samples[reading.pid] = Sample(value: reading.value, unit: reading.unit, atMs: reading.atMs)
        }
        self.runTimeSeconds = runTimeSeconds
    }

    /// Unchecked value. Prefer `fresh(_:)` inside health checks.
    public subscript(pid: UInt8) -> Double? { samples[pid]?.value }

    /// Value only when it was observed within `maxAgeMs` of the reference time.
    public func fresh(_ pid: UInt8, maxAgeMs: Int = 5_000) -> Double? {
        guard let sample = samples[pid] else { return nil }
        let age = referenceMs - sample.atMs
        guard age >= 0, age <= maxAgeMs else { return nil }
        return sample.value
    }

    /// Age of the observation, or nil when there is none.
    public func ageMs(_ pid: UInt8) -> Int? {
        samples[pid].map { referenceMs - $0.atMs }
    }

    public func unit(_ pid: UInt8) -> String? { samples[pid]?.unit }

    public mutating func set(_ pid: UInt8, _ value: Double, unit: String, atMs: Int? = nil) {
        samples[pid] = Sample(value: value, unit: unit, atMs: atMs ?? referenceMs)
    }
}

public enum PID {
    public static let load: UInt8 = 0x04
    public static let coolant: UInt8 = 0x05
    public static let map: UInt8 = 0x0B
    public static let rpm: UInt8 = 0x0C
    public static let speed: UInt8 = 0x0D
    public static let intakeTemp: UInt8 = 0x0F
    public static let maf: UInt8 = 0x10
    public static let railPressure: UInt8 = 0x23
    public static let barometric: UInt8 = 0x33
    public static let catTemp: UInt8 = 0x3C
    public static let moduleVoltage: UInt8 = 0x42
    public static let runTime: UInt8 = 0x1F
}

public enum VehicleSpec {

    /// Idle speed by coolant temperature, from the data list (items 2 and 56).
    /// Mitsubishi specifies a band per temperature rather than one number.
    public static func idleSpeedBand(coolantC: Double) -> ClosedRange<Double>? {
        switch coolantC {
        case ..<(-10): return 870...930
        case ..<12.5: return 760...820
        case ..<32.5: return 660...720
        case ..<60: return 620...680
        case ..<200: return 620...680
        default: return nil
        }
    }

    /// Item 64: rail pressure target at idle is 20-35 MPa.
    public static let idleRailPressureBar: ClosedRange<Double> = 200...350

    /// Item 63: measured rail pressure must be within +/-10 MPa of target at idle.
    public static let railPressureToleranceBar: Double = 100

    /// Item 114: air flow at idle, 200-935 mg/cyl.
    public static let idleAirFlowMgPerCyl: ClosedRange<Double> = 200...935

    /// Charging voltage with the engine running. Not a manual figure; a
    /// conventional 12 V alternator band.
    public static let chargingVolts: ClosedRange<Double> = 13.5...14.8

    /// Resting voltage, engine off. A healthy lead-acid battery sits here.
    /// Below `restingVoltsSuspect` it is on the way out.
    public static let restingVoltsHealthy: ClosedRange<Double> = 12.2...12.9
    public static let restingVoltsSuspect: Double = 12.0

    /// Minutes the vehicle must have been off before a voltage reading counts
    /// as a resting measurement rather than a surface-charge artefact.
    public static let restingSettleMinutes: Int = 30

    /// Convert g/s from PID 0x10 into mg per cylinder per stroke.
    /// Four cylinders, four-stroke: intake events per second = rpm / 30.
    public static func airFlowMgPerCylinder(gramsPerSecond: Double, rpm: Double) -> Double? {
        guard rpm > 0 else { return nil }
        let eventsPerSecond = rpm / 30.0
        return (gramsPerSecond * 1000.0) / eventsPerSecond
    }

    /// Boost pressure is not a PID on this ECU; derive it from MAP and barometric.
    public static func boostKPa(map: Double, barometric: Double) -> Double {
        map - barometric
    }
}

public enum HealthEvaluator {

    /// Idle-only checks. Caller decides when the car is actually idling.
    public static func evaluateIdle(_ set: ReadingSet, maxAgeMs: Int = 5_000) -> [Finding] {
        var findings: [Finding] = []

        if let rpm = set.fresh(PID.rpm, maxAgeMs: maxAgeMs),
           let coolant = set.fresh(PID.coolant, maxAgeMs: maxAgeMs) {
            if let band = VehicleSpec.idleSpeedBand(coolantC: coolant) {
                let severity: Severity = band.contains(rpm) ? .ok : .suspect
                findings.append(Finding(
                    key: "idle_speed",
                    label: "Idle speed",
                    severity: severity,
                    message: severity == .ok
                        ? "\(Int(rpm)) rpm is inside \(Int(band.lowerBound))-\(Int(band.upperBound)) for \(Int(coolant)) °C coolant"
                        : "\(Int(rpm)) rpm is outside \(Int(band.lowerBound))-\(Int(band.upperBound)) for \(Int(coolant)) °C coolant",
                    source: .serviceManual(item: 2),
                    observed: rpm,
                    unit: "rpm"
                ))
            }
        }

        if let rail = set.fresh(PID.railPressure, maxAgeMs: maxAgeMs),
           let rpm = set.fresh(PID.rpm, maxAgeMs: maxAgeMs), rpm < 900 {
            let band = VehicleSpec.idleRailPressureBar
            let severity: Severity = band.contains(rail) ? .ok : .suspect
            findings.append(Finding(
                key: "rail_pressure_idle",
                label: "Rail pressure at idle",
                severity: severity,
                message: severity == .ok
                    ? "\(Int(rail)) bar inside the 200-350 bar target band"
                    : "\(Int(rail)) bar outside the 200-350 bar target band",
                source: .serviceManual(item: 64),
                observed: rail,
                unit: "bar"
            ))
        }

        if let maf = set.fresh(PID.maf, maxAgeMs: maxAgeMs),
           let rpm = set.fresh(PID.rpm, maxAgeMs: maxAgeMs), rpm > 0, rpm < 900,
           let perCyl = VehicleSpec.airFlowMgPerCylinder(gramsPerSecond: maf, rpm: rpm) {
            let band = VehicleSpec.idleAirFlowMgPerCyl
            let severity: Severity = band.contains(perCyl) ? .ok : .suspect
            findings.append(Finding(
                key: "air_flow_idle",
                label: "Air flow per cylinder",
                severity: severity,
                message: severity == .ok
                    ? "\(Int(perCyl)) mg/cyl inside 200-935"
                    : "\(Int(perCyl)) mg/cyl outside 200-935",
                source: .serviceManual(item: 114),
                observed: perCyl,
                unit: "mg/cyl"
            ))
        }

        return findings
    }

    /// Checks that apply whenever the engine is running.
    public static func evaluateRunning(_ set: ReadingSet, maxAgeMs: Int = 5_000) -> [Finding] {
        var findings: [Finding] = []

        if let volts = set.fresh(PID.moduleVoltage, maxAgeMs: maxAgeMs) {
            let band = VehicleSpec.chargingVolts
            let severity: Severity = band.contains(volts) ? .ok : .watch
            findings.append(Finding(
                key: "charging_voltage",
                label: "Charging voltage",
                severity: severity,
                message: severity == .ok
                    ? String(format: "%.2f V inside 13.5-14.8 V", volts)
                    : String(format: "%.2f V outside 13.5-14.8 V", volts),
                source: .heuristic("conventional 12 V alternator band"),
                observed: volts,
                unit: "V"
            ))
        }

        // A thermostat that has failed open shows as coolant never reaching
        // operating temperature despite a long run time.
        if let coolant = set.fresh(PID.coolant, maxAgeMs: maxAgeMs),
           let runTime = set.runTimeSeconds ?? set.fresh(PID.runTime, maxAgeMs: maxAgeMs) {
            if runTime > 900, coolant < 70 {
                findings.append(Finding(
                    key: "coolant_warmup",
                    label: "Coolant warm-up",
                    severity: .suspect,
                    message: "Only \(Int(coolant)) °C after \(Int(runTime / 60)) min running",
                    source: .heuristic("thermostat stuck open pattern"),
                    observed: coolant,
                    unit: "°C"
                ))
            }
        }

        if let map = set.fresh(PID.map, maxAgeMs: maxAgeMs),
           let baro = set.fresh(PID.barometric, maxAgeMs: maxAgeMs) {
            let boost = VehicleSpec.boostKPa(map: map, barometric: baro)
            if boost < -10 {
                findings.append(Finding(
                    key: "boost_sanity",
                    label: "Boost pressure",
                    severity: .watch,
                    message: String(format: "MAP is %.0f kPa below barometric — check the MAP sensor", boost),
                    source: .heuristic("manifold pressure cannot sit below ambient while running"),
                    observed: boost,
                    unit: "kPa"
                ))
            }
        }

        return findings
    }

    /// Battery health, engine off. This is the check that catches a battery
    /// degrading weeks before it strands the car.
    ///
    /// A resting measurement requires the engine to have been off and the
    /// surface charge to have dissipated. PID 0x42 read with the ignition on is
    /// **not** a resting measurement: it includes ECU load and voltage drop, so
    /// it gets an observation, never a battery verdict.
    public static func evaluateBattery(
        _ set: ReadingSet,
        powerState: PowerState,
        maxAgeMs: Int = 5_000
    ) -> [Finding] {
        guard let volts = set.fresh(PID.moduleVoltage, maxAgeMs: maxAgeMs) else { return [] }

        switch powerState {
        case .running:
            return []

        case .ignitionOn:
            // Explicitly not a diagnosis. Report the observation and say why.
            let low = volts < VehicleSpec.restingVoltsSuspect
            return [Finding(
                key: "voltage_ignition_on",
                label: "Voltage, ignition on",
                severity: low ? .watch : .ok,
                message: low
                    ? String(format: "%.1f V with the ignition on — not a resting measurement. Check with the engine off and settled, or measure at the terminals.", volts)
                    : String(format: "%.1f V with the ignition on", volts),
                source: .heuristic("ignition-on voltage includes ECU and accessory load"),
                observed: volts,
                unit: "V"
            )]

        case .resting(let settledMinutes):
            guard settledMinutes >= VehicleSpec.restingSettleMinutes else {
                return [Finding(
                    key: "voltage_ignition_on",
                    label: "Voltage, recently stopped",
                    severity: .watch,
                    message: String(format: "%.1f V only %d min after stopping — surface charge has not settled. Re-check after %d min.",
                                    volts, settledMinutes, VehicleSpec.restingSettleMinutes),
                    source: .heuristic("surface charge dissipates over tens of minutes"),
                    observed: volts,
                    unit: "V"
                )]
            }

            if VehicleSpec.restingVoltsHealthy.contains(volts) {
                return [Finding(
                    key: "battery_resting",
                    label: "Battery at rest",
                    severity: .ok,
                    message: String(format: "%.1f V — healthy", volts),
                    source: .heuristic("12.2-12.9 V resting band for a 12 V lead-acid battery"),
                    observed: volts,
                    unit: "V"
                )]
            }

            let suspect = volts < VehicleSpec.restingVoltsSuspect
            return [Finding(
                key: "battery_resting",
                label: "Battery at rest",
                severity: suspect ? .suspect : .watch,
                message: suspect
                    ? String(format: "%.1f V after settling — battery is degrading", volts)
                    : String(format: "%.1f V after settling — below the healthy 12.2-12.9 V band", volts),
                source: .heuristic("12.2-12.9 V resting band for a 12 V lead-acid battery"),
                observed: volts,
                unit: "V"
            )]
        }
    }

    /// Convenience: everything currently known to be checkable.
    public static func evaluate(
        _ set: ReadingSet,
        powerState: PowerState,
        isIdle: Bool,
        maxAgeMs: Int = 5_000
    ) -> [Finding] {
        var findings: [Finding] = []
        if isIdle { findings += evaluateIdle(set, maxAgeMs: maxAgeMs) }
        if powerState == .running {
            findings += evaluateRunning(set, maxAgeMs: maxAgeMs)
        }
        findings += evaluateBattery(set, powerState: powerState, maxAgeMs: maxAgeMs)
        return findings
    }

    public static func worst(_ findings: [Finding]) -> Severity {
        if findings.contains(where: { $0.severity == .suspect }) { return .suspect }
        if findings.contains(where: { $0.severity == .watch }) { return .watch }
        if findings.isEmpty { return .insufficientData }
        return .ok
    }
}
