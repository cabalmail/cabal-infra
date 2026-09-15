import Foundation

/// HTML → plain text extraction: `plainText` for search, `firstLine` for a
/// list row's preview.
///
/// Built for the Spotlight donation path when a message has no
/// `text/plain` alternative: the goal is the *words* of the message, not
/// rendering fidelity, so this is a deliberate non-parser — drop the
/// non-content blocks, replace tags with spaces, decode the entities that
/// actually occur in mail, collapse whitespace. `NSAttributedString`'s HTML
/// importer would be higher fidelity but is WebKit-backed and main-thread-
/// bound — the wrong tool for a background indexing path, or for a row.
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

    /// The first line of prose in an HTML body, for a list row's preview
    /// line. Block-level tags (`p`, `div`, `br`, `li`, headings, cells, …)
    /// end a line, inline tags vanish, script/style/head/comments are
    /// skipped, entities decode, and whitespace collapses to single spaces.
    /// The scan stops as soon as the line is complete, so the cost is the
    /// distance to the first prose rather than the size of the body — cheap
    /// enough to call from a row's `body`. A line longer than `maxLength` is
    /// cut there with an ellipsis; the row's own tail truncation handles
    /// the column width. Returns "" when the body has no prose.
    public static func firstLine(from html: String, maxLength: Int = 500) -> String {
        // Raw budget: the scan stops once this much markup-free text is in
        // hand; decoding and collapsing can only shrink it from there.
        var scanner = FirstLineScanner(html: html, rawBudget: maxLength * 4)
        scanner.run()
        var cutShort = scanner.cutShort
        var text = decodeEntities(scanner.raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if text.count > maxLength {
            text = String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
            cutShort = true
        }
        return cutShort && !text.isEmpty ? text + "…" : text
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

/// The scan behind `HTMLText.firstLine`: one pass over the markup that
/// stops at the end of the first line of prose.
private struct FirstLineScanner {
    /// Tags whose contents are not prose; the scan skips past their closing
    /// tag.
    private static let skippedTags: Set<String> = ["script", "style", "head"]

    /// Tags that start or end a line of prose. Inline tags (`a`, `b`, `em`,
    /// `span`, …) are deliberately absent so "wor<b>d</b>" stays a word.
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "br", "dd", "details", "div", "dl",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "html", "li", "main", "nav", "ol", "p", "pre", "section", "summary",
        "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    private let rawBudget: Int
    private var rest: Substring
    /// The markup-free text of the line so far, entities still encoded.
    private(set) var raw = ""
    private var rawCount = 0
    /// True when the line ran past the raw budget before it ended.
    private(set) var cutShort = false

    init(html: String, rawBudget: Int) {
        self.rawBudget = rawBudget
        rest = Substring(html)
    }

    mutating func run() {
        while !rest.isEmpty {
            guard let tagStart = rest.firstIndex(of: "<") else {
                append(rest)
                return
            }
            append(rest[..<tagStart])
            if cutShort { return }
            rest = rest[tagStart...]
            if rest.hasPrefix("<!--") {
                skip(past: "-->")
                continue
            }
            guard let tag = tagName() else {
                appendBareBracket()
                continue
            }
            guard let tagEnd = rest[tag.end...].firstIndex(of: ">") else {
                // An unterminated pseudo-tag is prose too, as in `plainText`.
                append(rest)
                return
            }
            rest = rest[rest.index(after: tagEnd)...]
            if consume(tag: tag.name) { return }
        }
    }

    /// The name of the tag at the head of `rest` and where the name ends,
    /// or nil for a bare `<` in prose ("a < b", "I <3 feeds"): a tag name
    /// starts with a letter.
    private func tagName() -> (name: String, end: Substring.Index)? {
        var start = rest.index(after: rest.startIndex)
        if start < rest.endIndex, rest[start] == "/" { start = rest.index(after: start) }
        guard start < rest.endIndex, rest[start].isLetter else { return nil }
        let end = rest[start...].firstIndex { !($0.isLetter || $0.isNumber) } ?? rest.endIndex
        return (rest[start..<end].lowercased(), end)
    }

    /// Applies a tag's effect on the line: a non-prose block is skipped, a
    /// block boundary ends the line when there is prose in hand and resets
    /// a blank one, an inline tag does nothing. True when the line is
    /// complete.
    private mutating func consume(tag name: String) -> Bool {
        if Self.skippedTags.contains(name) {
            skip(pastClosingTag: name)
            return false
        }
        guard Self.blockTags.contains(name) else { return false }
        if hasProse { return true }
        raw = ""
        rawCount = 0
        return false
    }

    private var hasProse: Bool {
        !HTMLText.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private mutating func append(_ text: Substring) {
        guard !cutShort, !text.isEmpty else { return }
        let taken = text.prefix(rawBudget - rawCount)
        raw += taken
        rawCount += taken.count
        if taken.endIndex < text.endIndex { cutShort = true }
    }

    private mutating func appendBareBracket() {
        let afterBracket = rest.index(after: rest.startIndex)
        append(rest[..<afterBracket])
        rest = rest[afterBracket...]
    }

    private mutating func skip(past marker: String) {
        guard let range = rest.range(of: marker) else {
            rest = ""
            return
        }
        rest = rest[range.upperBound...]
    }

    private mutating func skip(pastClosingTag name: String) {
        guard let range = rest.range(of: "</\(name)", options: .caseInsensitive),
              let tagEnd = rest[range.upperBound...].firstIndex(of: ">") else {
            rest = ""
            return
        }
        rest = rest[rest.index(after: tagEnd)...]
    }
}
