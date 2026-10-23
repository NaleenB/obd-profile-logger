import Foundation

/// The baseline every compliant vehicle supports, used when no profile is
/// present. These are the classic OBD-II PIDs that have existed since 1996.
///
/// This is a **fallback**, not a preference: capability discovery filters it to
/// what the car actually answers, so an unsupported signal simply disappears
/// instead of showing a permanent dash.
public enum GenericSignals {

    public static let defaults: [VehicleProfile.StandardSignal] = [
        .init(pid: "0C", name: "Engine speed", unit: "rpm", bytes: 2,
              factor: 0.25, offset: 0, decimals: 0),
        .init(pid: "0D", name: "Vehicle speed", unit: "km/h", bytes: 1,
              factor: 1, offset: 0, decimals: 0),
        .init(pid: "05", name: "Coolant", unit: "degC", bytes: 1,
              factor: 1, offset: -40, decimals: 0),
        .init(pid: "04", name: "Load", unit: "%", bytes: 1,
              factor: 100.0 / 255.0, offset: 0, decimals: 0),
        .init(pid: "0B", name: "Intake MAP", unit: "kPa", bytes: 1,
              factor: 1, offset: 0, decimals: 0),
        .init(pid: "0F", name: "Intake air", unit: "degC", bytes: 1,
              factor: 1, offset: -40, decimals: 0),
        .init(pid: "10", name: "Mass air flow", unit: "g/s", bytes: 2,
              factor: 0.01, offset: 0, decimals: 2),
        .init(pid: "11", name: "Throttle", unit: "%", bytes: 1,
              factor: 100.0 / 255.0, offset: 0, decimals: 0),
        .init(pid: "2F", name: "Fuel level", unit: "%", bytes: 1,
              factor: 100.0 / 255.0, offset: 0, decimals: 0),
        .init(pid: "42", name: "Module voltage", unit: "V", bytes: 2,
              factor: 0.001, offset: 0, decimals: 2)
    ]
}

/// Decodes mode `01` supported-PID bitmaps.
public enum PIDCapabilities {

    /// Expands a four-byte bitmap into the PIDs it advertises.
    /// `base` is the bitmap's own PID: `0x00` covers `01`-`20`, `0x20` covers
    /// `21`-`40`, and so on.
    public static func expand(bitmap: [UInt8], base: UInt8) -> Set<UInt8> {
        var supported: Set<UInt8> = []
        for (byteIndex, byte) in bitmap.enumerated() {
            for bit in 0..<8 where byte & (0x80 >> UInt8(bit)) != 0 {
                let value = Int(base) + byteIndex * 8 + bit + 1
                if value <= 0xFF { supported.insert(UInt8(value)) }
            }
        }
        return supported
    }

    /// Parses a reply such as `4100BE1FA813` for the bitmap starting at `pid`.
    /// Returns nil when the reply is not a bitmap.
    public static func supported(fromHex hex: String, base: UInt8) -> Set<UInt8>? {
        let header = String(format: "41%02X", base)
        guard hex.hasPrefix(header) else { return nil }
        let tail = String(hex.dropFirst(header.count))
        guard let bytes = bytes(fromHex: tail), bytes.count >= 4 else { return nil }
        return expand(bitmap: Array(bytes.prefix(4)), base: base)
    }

    /// The bitmap queries worth asking, in order.
    public static let probePIDs: [UInt8] = [0x00, 0x20, 0x40, 0x60]

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
