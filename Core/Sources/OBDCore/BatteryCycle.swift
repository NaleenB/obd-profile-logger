/// One polling cycle's battery-relevant observations.
///
/// Battery classification needs RPM and voltage from the same pass. Passing a
/// cached RPM beside a fresh crank voltage hides the dip, and a cached voltage
/// beside a fresh RPM records a crank minimum from an earlier cycle. Building
/// the pair through this value type makes that mistake impossible: a failed
/// read contributes `nil`, never the previous cycle's value.
public struct BatteryCycle: Equatable {

    public private(set) var rpm: Double?
    public private(set) var volts: Double?

    public init() {}

    /// Records a successful standard-PID observation. Failed reads are simply
    /// not recorded, which leaves the corresponding side `nil` for this cycle.
    public mutating func record(pid: UInt8, value: Double?) {
        guard let value else { return }
        switch pid {
        case 0x0C: rpm = value
        case 0x42: volts = value
        default: break
        }
    }

    /// The pair to feed the monitor. No voltage means there is nothing to
    /// classify; a missing RPM is passed as `nil` so the voltage fallback can
    /// still detect a crank.
    public var voltageSample: (volts: Double, rpm: Double?)? {
        guard let volts else { return nil }
        return (volts, rpm)
    }
}
