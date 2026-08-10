import Foundation

/// Search-oriented HTML → plain text extraction.
///
/// Built for the Spotlight donation path when a message has no
/// `text/plain` alternative: the goal is the *words* of the message, not
/// rendering fidelity, so this is a deliberate non-parser — drop the
/// non-content blocks, replace tags with spaces, decode the entities that
/// actually occur in mail, collapse whitespace. `NSAttributedString`'s HTML
/// importer would be higher fidelity but is WebKit-backed and main-thread-
/// bound — the wrong tool for a background indexing path.
public enum HTMLText {
    /// Extracts readable text from an HTML body. Returns "" when the body
    /// has no prose (e.g. an image-only message).
    public static func plainText(from html: String) -> String {
        var text = html
        // Drop non-content blocks wholesale — their contents are code, not
        // prose. `(?i)` for SCRIPT/STYLE casing, `(?s)` so the block match
        // spans newlines.
        for pattern in [
            "(?is)<script\\b[^>]*>.*?</script>",
            "(?is)<style\\b[^>]*>.*?</style>",
            "(?s)<!--.*?-->",
        ] {
            text = text.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression
            )
        }
        // Tags become spaces (not empty string) so `…word</td><td>word…`
        // doesn't concatenate across cell/paragraph boundaries.
        text = text.replacingOccurrences(
            of: "(?s)<[^>]*>", with: " ", options: .regularExpression
        )
        text = decodeEntities(text)
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The named entities worth decoding for search: the XML five plus the
    /// typographic set mail templates actually emit. Unknown entities pass
    /// through literally, which is harmless in an index.
    private static let namedEntities: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•",
    ]

    static func decodeEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var result = ""
        result.reserveCapacity(input.count)
        var index = input.startIndex
        while let amp = input[index...].firstIndex(of: "&") {
            result += input[index..<amp]
            // An entity's `;` sits within a handful of characters; a bare
            // `&` in prose won't have one nearby and passes through.
            let searchEnd = input.index(amp, offsetBy: 12, limitedBy: input.endIndex)
                ?? input.endIndex
            if let semi = input[amp..<searchEnd].firstIndex(of: ";"),
               let decoded = decodeEntity(String(input[input.index(after: amp)..<semi])) {
                result.append(decoded)
                index = input.index(after: semi)
            } else {
                result.append("&")
                index = input.index(after: amp)
            }
        }
        result += input[index...]
        return result
    }

    private static func decodeEntity(_ body: String) -> Character? {
        if body.hasPrefix("#x") || body.hasPrefix("#X") {
            guard let value = UInt32(body.dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
        if body.hasPrefix("#") {
            guard let value = UInt32(body.dropFirst(), radix: 10),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return Character(scalar)
        }
        return namedEntities[body]
    }
}
