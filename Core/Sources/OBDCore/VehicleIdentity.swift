import Foundation

/// Identifiers a car reports about itself, used to decide which profile fits.
///
/// Capability alone is not enough: several Mitsubishi models answer service
/// `0x21` with completely different block layouts, so "it speaks the service"
/// does not mean "these offsets apply".
public struct VehicleIdentity: Equatable, Sendable {
    public var vin: String?
    /// Mode `09` PID `04`. An ECU software identifier — precise, and not
    /// personally identifying.
    public var calibrationID: String?

    public init(vin: String? = nil, calibrationID: String? = nil) {
        self.vin = vin
        self.calibrationID = calibrationID
    }
}

public enum VehicleIdentityDecoder {

    /// Decodes a mode `09` PID `02` reply such as
    /// `4902014A4D46…` into `JMFXLGF6W…`.
    public static func vin(fromHex hex: String) -> String? {
        text(fromHex: hex, header: "4902")
    }

    /// Decodes a mode `09` PID `04` reply into the calibration identifier.
    public static func calibrationID(fromHex hex: String) -> String? {
        text(fromHex: hex, header: "4904")
    }

    private static func text(fromHex hex: String, header: String) -> String? {
        let cleaned = hex.filter { !$0.isWhitespace }.uppercased()
        guard cleaned.hasPrefix(header) else { return nil }

        var tail = String(cleaned.dropFirst(header.count))
        // First byte is a frame counter (0x01); drop it.
        if tail.count >= 2 { tail = String(tail.dropFirst(2)) }

        guard let bytes = bytes(fromHex: tail) else { return nil }
        let printable = bytes.prefix { $0 != 0x00 }.filter { $0 >= 0x20 && $0 < 0x7F }
        let text = String(decoding: printable, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}
