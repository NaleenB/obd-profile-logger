import Foundation

/// True when every visible character is a hex digit. Used to tell real data
/// apart from status words such as "NO DATA".
func looksLikeHex(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    return trimmed.allSatisfy { $0.isHexDigit || $0 == " " }
}

func bytesFromHex(_ text: String) -> [UInt8]? {
    let cleaned = text.filter { !$0.isWhitespace }
    guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else { return nil }
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

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

func isoNow() -> String { isoFormatter.string(from: Date()) }

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}
