import Foundation

/// Small protocol predicates used to decide whether a CAN module header is
/// meaningful.
public enum OBDProtocol {

    /// True for an ELM327 protocol identifier such as `6`, `A6`, or an
    /// `ATDP` description containing `15765`.
    ///
    /// `ATDPN` prefixes an auto-detected protocol with `A`, so checking for an
    /// exact `"6"` would miss the common `A6` form. The non-CAN protocols
    /// (`0`-`5`, `A`, `B`, `C`) must not be handed `7E0`: their headers have a
    /// different length and the request is simply lost.
    public static func isCAN(_ identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        let upper = identifier.uppercased()
        if upper.contains("15765") { return true }
        return upper.range(
            of: #"(^|[^0-9])[6-9]([^0-9]|$)"#,
            options: .regularExpression) != nil
    }

    /// True for the 29-bit CAN protocols (`7`, `9`, `A7`, `A9`) and their
    /// descriptions. `7E0` is an 11-bit address and is not valid on these.
    public static func isCAN29Bit(_ identifier: String?) -> Bool {
        guard let identifier, !identifier.isEmpty else { return false }
        let upper = identifier.uppercased()
        if upper.contains("15765"), upper.contains("29") { return true }
        return upper.range(
            of: #"(^|[^0-9])[79]([^0-9]|$)"#,
            options: .regularExpression) != nil
    }

    /// The header for standard mode-`01` and manufacturer reads.
    ///
    /// A profile's `7E0` is the 11-bit engine address, so on 29-bit CAN it must
    /// fall back to broadcast; the generic profile also tells a 29-bit owner to
    /// set `elmProtocol` to `0`, which makes this path reachable. A profile that
    /// names a different engine header (for example an 8-digit 29-bit address)
    /// is trusted on any bus, and a non-CAN bus keeps broadcast because `7E0`
    /// would simply be lost there.
    public static func engineHeader(
        profileHeader: String?,
        protocolIdentifier: String?
    ) -> String {
        if let profileHeader, profileHeader.uppercased() != "7E0" {
            return profileHeader
        }
        guard let protocolIdentifier,
              isCAN(protocolIdentifier),
              !isCAN29Bit(protocolIdentifier)
        else { return "7DF" }
        return "7E0"
    }
}
