import Foundation

/// The rules `set_preferences` holds the typed values of the `app` map to
/// (`lambda/api/set_preferences/function.py`): a flag's name and the
/// signature. The server refuses the whole map, with a 400, when one value
/// breaks them (#2439), so `Preferences` keeps every value it holds within
/// them, on each write and at each reload.
///
/// The server counts with Python's `len()`, which counts Unicode code
/// points. Swift's `count` counts characters as the user sees them, and an
/// emoji or a letter with combining marks is one character of several code
/// points, so a cut by characters can leave a value the server refuses.
/// These cut by code points, and at a character boundary, so no character
/// is split.
public enum ServerTextRules {
    /// The longest signature the server takes, in code points
    /// (`MAX_SIGNATURE_LENGTH`).
    public static let maxSignatureLength = 2000

    /// A flag's name as the server takes it: control characters (below
    /// U+0020, and U+007F) dropped, then cut to `FlagPalette.maxLabelLength`
    /// code points. It can come out empty, which the server refuses too:
    /// the flag editor writes no such name, and `FlagPalette.accepted(_:)`
    /// names an entry stored with one.
    public static func flagLabel(_ label: String) -> String {
        cut(keeping(label) { !isControl($0) }, toCodePoints: FlagPalette.maxLabelLength)
    }

    /// The signature as the server takes it: a CR LF or a lone CR becomes a
    /// newline, other control characters but newline and tab are dropped,
    /// and the rest is cut to `maxSignatureLength` code points.
    public static func signature(_ signature: String) -> String {
        let lines = signature.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let kept = keeping(lines) { $0 == "\n" || $0 == "\t" || !isControl($0) }
        return cut(kept, toCodePoints: maxSignatureLength)
    }

    /// The longest run of whole characters from the start of `text` whose
    /// code points number `limit` or fewer.
    static func cut(_ text: String, toCodePoints limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var kept = 0
        var end = text.startIndex
        for index in text.indices {
            let scalars = text[index].unicodeScalars.count
            guard kept + scalars <= limit else { break }
            kept += scalars
            end = text.index(after: index)
        }
        return String(text[..<end])
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func keeping(_ text: String, _ include: (Unicode.Scalar) -> Bool) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter(include))
        return String(scalars)
    }
}

extension FlagPalette {
    /// What Settings names a new flag, and the name a flag of the user's
    /// own gets back when it is stored with an empty one.
    public static let newFlagLabel = "New flag"

    /// `entries` with every name as the server takes it
    /// (`ServerTextRules.flagLabel(_:)`); a name that comes out empty is
    /// the entry's default one (`defaultLabel(forSlot:)`). The flag editor
    /// writes no such name, so this names an entry that got one another
    /// way: 1.52.0 stored a cleared name as it was typed.
    public static func accepted(_ entries: [FlagPaletteEntry]) -> [FlagPaletteEntry] {
        entries.map { entry in
            var entry = entry
            let label = ServerTextRules.flagLabel(entry.label)
            entry.label = label.isEmpty ? defaultLabel(forSlot: entry.slot) : label
            return entry
        }
    }

    /// The name an entry has before the user gives it one: the built-in
    /// flag's own for its entry ("Flagged"), `newFlagLabel` for any other.
    public static func defaultLabel(forSlot slot: String) -> String {
        slot == systemSlot ? defaultSystemEntry.label : newFlagLabel
    }
}
