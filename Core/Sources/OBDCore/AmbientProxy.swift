import Foundation

/// An ambient estimate taken from intake air temperature.
///
/// This ECU declares no ambient-temperature PID (`0x46` is absent from its
/// capability bitmap), so intake air stands in for it. That substitution only
/// holds before the engine starts: while it runs the intake is heat-soaked, and
/// a 2 h soak still read 61 °C against a 45 °C engine bay. Filing that as
/// ambient would put a manifold temperature into a field every consumer expects
/// to describe the weather, so a running engine makes the value unknown rather
/// than merely warm.
public enum AmbientProxy {
    /// - Parameters:
    ///   - intakeAirC: PID `0F`, or nil when the ECU did not answer.
    ///   - rpm: PID `0C`, or nil when the ECU did not answer. A failed read is
    ///     not evidence the engine was off, so it also yields nil.
    public static func value(intakeAirC: Double?, rpm: Double?) -> Double? {
        guard let intakeAirC, let rpm, rpm < BatteryMonitor.runningRpm else { return nil }
        return intakeAirC
    }
}
