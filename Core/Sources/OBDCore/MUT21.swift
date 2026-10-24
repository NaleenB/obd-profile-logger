import Foundation

/// Decoder for Mitsubishi/KWP2000 service `0x21` (ReadDataByLocalIdentifier)
/// responses from the 4N14 engine ECU.
///
/// Byte offsets in the MUT-III database are **absolute within the response
/// frame**, counting the `0x61` service byte and the local identifier. This was
/// established empirically, not assumed: item 1 (battery voltage) decodes to
/// 12.3 V only under absolute indexing, and item 2 (engine revolution) decodes
/// to 0 rpm with the engine off — both correct, while the data-relative
/// interpretation gives 0.0 V and 1625 rpm.
public struct MUT21Frame {
    public let localIdentifier: UInt8
    public let bytes: [UInt8]

    public init?(hex: String) {
        guard let raw = Self.decodeHex(hex), raw.count >= 2,
              raw[0] == 0x61
        else { return nil }
        self.localIdentifier = raw[1]
        self.bytes = raw
    }

    /// Reads a big-endian unsigned value at an absolute frame offset.
    public func value(at offset: Int, length: Int) -> Int? {
        guard length > 0, offset >= 0, offset + length <= bytes.count else { return nil }
        var result = 0
        for index in offset..<(offset + length) {
            result = (result << 8) | Int(bytes[index])
        }
        return result
    }

    private static func decodeHex(_ text: String) -> [UInt8]? {
        let cleaned = text.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
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

/// Diesel particulate filter state as reported by the engine ECU.
public struct DPFStatus: Equatable {
    /// Soot load estimate from the fuel-quantity model, g/L. Range 0-12.75.
    public let sootByAccumulation: Double?
    /// Soot load estimate from the differential pressure sensor, g/L.
    public let sootByPressure: Double?
    /// Lifetime regeneration count.
    public let regenerationCount: Int?
    /// Raw regeneration mode, preserved because its enum mapping is not
    /// established beyond "0 means not requested".
    public let regenerationMode: RegenerationMode?

    public init(sootByAccumulation: Double? = nil,
                sootByPressure: Double? = nil,
                regenerationCount: Int? = nil,
                regenerationMode: RegenerationMode? = nil) {
        self.sootByAccumulation = sootByAccumulation
        self.sootByPressure = sootByPressure
        self.regenerationCount = regenerationCount
        self.regenerationMode = regenerationMode
    }
}

public enum RegenerationMode: Equatable {
    /// The ECU reports no regeneration is wanted. Value 0 is confirmed by a
    /// real capture.
    case notRequested
    /// A non-zero mode whose meaning has not been established. Reported as
    /// unknown rather than guessed at.
    case unknown(raw: Int)
}
