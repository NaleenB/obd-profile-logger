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
}
