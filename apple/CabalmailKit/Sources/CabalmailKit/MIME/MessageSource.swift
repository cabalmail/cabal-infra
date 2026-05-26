import Foundation

/// Helpers for surfacing the raw RFC 5322 source of a message to the
/// "View Source" UI. The sheet renders three tabs (Full / Headers /
/// Body); the work of decoding the bytes and finding the headers/body
/// split lives here so the view stays a thin presenter and the logic
/// is reachable from `swift test`.
///
/// The split rule is the same one every MUA uses: scan for the first
/// blank line, treating `\r\n\r\n` and `\n\n` as equivalent because mail
/// arriving through different gateways can land either way. A message
/// with no body separator (an envelope-only artifact, or a manually
/// truncated fixture) yields the full input as headers and an empty
/// body — preferable to throwing, since the sheet still has something
/// to render and the user can see what they got.
public enum MessageSource {
    /// Decode raw RFC 5322 bytes for display. UTF-8 first, then Latin-1
    /// — mail headers routinely smuggle in non-ASCII via RFC 2047
    /// encoded-words, but the surrounding wrapper is 7-bit ASCII or
    /// 8-bit MIME, both of which round-trip through Latin-1 without
    /// loss. The fallback never throws so a corrupt byte run can't
    /// hide the rest of the message from the user.
    public static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Splits raw source into (headers, body) on the first blank line.
    /// CRLF CRLF wins over LF LF when both appear, because that's the
    /// RFC 5322 canonical separator and a stray bare LF earlier in the
    /// headers shouldn't truncate them.
    public static func split(_ raw: String) -> (headers: String, body: String) {
        let crlfRange = raw.range(of: "\r\n\r\n")
        let lfRange = raw.range(of: "\n\n")
        let separator: Range<String.Index>?
        switch (crlfRange, lfRange) {
        case let (.some(crlf), .some(barelf)):
            separator = crlf.lowerBound <= barelf.lowerBound ? crlf : barelf
        case (.some(let crlf), nil):
            separator = crlf
        case (nil, .some(let barelf)):
            separator = barelf
        default:
            separator = nil
        }
        guard let separator else { return (raw, "") }
        return (
            String(raw[..<separator.lowerBound]),
            String(raw[separator.upperBound...])
        )
    }
}
