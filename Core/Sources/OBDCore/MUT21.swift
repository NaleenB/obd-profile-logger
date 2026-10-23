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

public enum MUT21 {

    // Scaling from the MUT-III data list: 1 byte, factor 0.05, giving a
    // 12.75 g/L ceiling. That matches the service manual's stated range for
    // data-list items 155 and 156, which is the cross-check that validates it.
    public static let sootGramsPerLitrePerBit = 0.05
    public static let sootMax = 12.75

    /// Local identifiers carrying the DPF block. Two of the five diesel ECU
    /// variants use `0x4C` instead of `0x11`, so both must be probed.
    public static let sootLIDs: [UInt8] = [0x11, 0x4C]
    public static let regenLID: UInt8 = 0x12

    /// Decodes a soot block (LID 0x11 or 0x4C).
    public static func decodeSoot(_ frame: MUT21Frame) -> (accumulation: Double?, pressure: Double?) {
        let accumulation = frame.value(at: 4, length: 1).map { Double($0) * sootGramsPerLitrePerBit }
        let pressure = frame.value(at: 5, length: 1).map { Double($0) * sootGramsPerLitrePerBit }
        return (accumulation, pressure)
    }

    /// Decodes the regeneration block (LID 0x12).
    ///
    /// The mode byte is an enum in the manufacturer data list, but only the
    /// zero case has been confirmed against a capture. Non-zero values are
    /// preserved as `.unknown(raw:)` rather than being flattened to "requested",
    /// which would assert something we cannot support.
    public static func decodeRegeneration(_ frame: MUT21Frame) -> (count: Int?, mode: RegenerationMode?) {
        let count = frame.value(at: 4, length: 2)
        let mode: RegenerationMode? = frame.value(at: 6, length: 1).map {
            $0 == 0 ? .notRequested : .unknown(raw: $0)
        }
        return (count, mode)
    }

    /// Builds a DPF status from whichever frames were answered.
    public static func status(from frames: [UInt8: MUT21Frame]) -> DPFStatus {
        var status = DPFStatus()

        for lid in sootLIDs {
            guard let frame = frames[lid] else { continue }
            let decoded = decodeSoot(frame)
            if decoded.accumulation != nil || decoded.pressure != nil {
                status = DPFStatus(
                    sootByAccumulation: decoded.accumulation,
                    sootByPressure: decoded.pressure,
                    regenerationCount: status.regenerationCount,
                    regenerationMode: status.regenerationMode
                )
                break
            }
        }

        if let frame = frames[regenLID] {
            let decoded = decodeRegeneration(frame)
            status = DPFStatus(
                sootByAccumulation: status.sootByAccumulation,
                sootByPressure: status.sootByPressure,
                regenerationCount: decoded.count,
                regenerationMode: decoded.mode
            )
        }

        return status
    }

    /// Fraction of the usable soot capacity that is currently loaded, 0...1.
    public static func sootFraction(_ status: DPFStatus) -> Double? {
        guard let soot = status.sootByAccumulation else { return nil }
        return min(max(soot / sootMax, 0), 1)
    }
}
