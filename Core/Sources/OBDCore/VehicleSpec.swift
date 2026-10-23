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
public struct ReadingSet {
    public private(set) var values: [UInt8: Double] = [:]
    public private(set) var units: [UInt8: String] = [:]
    public private(set) var runTimeSeconds: Double?

    public init() {}

    public init(readings: [Reading], runTimeSeconds: Double? = nil) {
        for reading in readings {
            values[reading.pid] = reading.value
            units[reading.pid] = reading.unit
        }
        self.runTimeSeconds = runTimeSeconds
    }

    public subscript(pid: UInt8) -> Double? { values[pid] }

    public mutating func set(_ pid: UInt8, _ value: Double, unit: String) {
        values[pid] = value
        units[pid] = unit
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
    public static func evaluateIdle(_ set: ReadingSet) -> [Finding] {
        var findings: [Finding] = []

        if let rpm = set[PID.rpm], let coolant = set[PID.coolant] {
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

        if let rail = set[PID.railPressure], let rpm = set[PID.rpm], rpm < 900 {
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

        if let maf = set[PID.maf], let rpm = set[PID.rpm], rpm > 0, rpm < 900,
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
    public static func evaluateRunning(_ set: ReadingSet) -> [Finding] {
        var findings: [Finding] = []

        if let volts = set[PID.moduleVoltage] {
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
        if let coolant = set[PID.coolant], let runTime = set.runTimeSeconds ?? set[PID.runTime] {
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

        if let map = set[PID.map], let baro = set[PID.barometric] {
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
    public static func evaluateBatteryResting(_ set: ReadingSet) -> [Finding] {
        guard let volts = set[PID.moduleVoltage] else { return [] }

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

        if volts < VehicleSpec.restingVoltsSuspect {
            return [Finding(
                key: "battery_resting",
                label: "Battery at rest",
                severity: .suspect,
                message: String(format: "%.1f V — below 12.0 V, battery is degrading", volts),
                source: .heuristic("12.2-12.9 V resting band for a 12 V lead-acid battery"),
                observed: volts,
                unit: "V"
            )]
        }

        return [Finding(
            key: "battery_resting",
            label: "Battery at rest",
            severity: .watch,
            message: String(format: "%.1f V — below the healthy 12.2-12.9 V band", volts),
            source: .heuristic("12.2-12.9 V resting band for a 12 V lead-acid battery"),
            observed: volts,
            unit: "V"
        )]
    }

    /// Convenience: everything currently known to be checkable.
    public static func evaluate(_ set: ReadingSet, isIdle: Bool) -> [Finding] {
        var findings: [Finding] = []
        if isIdle { findings += evaluateIdle(set) }
        findings += evaluateRunning(set)
        return findings
    }

    public static func worst(_ findings: [Finding]) -> Severity {
        if findings.contains(where: { $0.severity == .suspect }) { return .suspect }
        if findings.contains(where: { $0.severity == .watch }) { return .watch }
        if findings.isEmpty { return .insufficientData }
        return .ok
    }
}
