import Foundation

/// PID scaling that both the UI and the recorder must agree on.
///
/// Kept in Core so a wrong factor cannot live in one place and be right in
/// another: the recorder persists whatever this returns.
public enum PIDScaling {

    /// PID `0x23`, fuel rail gauge pressure.
    ///
    /// Raw is `((A * 256) + B)` at 10 kPa per bit. The UI displays bar, so the
    /// conversion is `raw * 10 kPa / 100 = raw / 10`.
    ///
    /// Worked example: raw `0x0D2C` = 3372 -> 33 720 kPa -> 337.2 bar.
    public static func railPressureBar(a: UInt8, b: UInt8) -> Double {
        railPressureBar(raw: (UInt16(a) << 8) | UInt16(b))
    }

    public static func railPressureBar(raw: UInt16) -> Double {
        Double(raw) * 10.0 / 100.0
    }

    /// Same value in kPa, for callers that prefer the native unit.
    public static func railPressureKPa(raw: UInt16) -> Double {
        Double(raw) * 10.0
    }
}
