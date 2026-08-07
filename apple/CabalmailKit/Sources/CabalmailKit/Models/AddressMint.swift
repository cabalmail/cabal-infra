import Foundation

/// Client-side helpers for minting new addresses.
///
/// The character pool and lengths mirror the React Request form
/// (`react/admin/src/Addresses/Request.jsx`) so addresses minted from any
/// surface — React, the in-app sheets, Siri — look the same. Kept in the Kit
/// so the app targets and the App Intents share one implementation and the
/// logic is covered by `swift test`.
public enum AddressMint {
    /// Character pool shared with the React Request form's Random button.
    public static let labelAlphabet = "abcdefghijklmnopqrstuvwxyz0123456789"

    /// Both random halves of `<username>@<subdomain>.<domain>` use 8 chars.
    public static let randomLabelLength = 8

    public static func randomLabel(length: Int = randomLabelLength) -> String {
        var generator = SystemRandomNumberGenerator()
        return randomLabel(length: length, using: &generator)
    }

    /// Deterministic variant for tests.
    public static func randomLabel(
        length: Int = randomLabelLength,
        using generator: inout some RandomNumberGenerator
    ) -> String {
        String((0..<max(0, length)).map { _ in labelAlphabet.randomElement(using: &generator) ?? "a" })
    }

    /// Normalizes free-form (often dictated) input into a token that passes
    /// the `/new` Lambda's local-part and DNS-label validation: diacritics
    /// folded, lowercased, whitespace / underscore / dot runs collapsed to
    /// single hyphens, everything else outside `[a-z0-9-]` dropped, hyphens
    /// trimmed from the ends, capped at 63 chars (the DNS label limit).
    /// Returns nil when nothing usable survives.
    public static func normalizeLabel(_ raw: String) -> String? {
        let folded = raw
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var result = ""
        var pendingHyphen = false
        for character in folded {
            if character.isWhitespace || character == "-" || character == "_" || character == "." {
                // Collapse separator runs; never lead with a hyphen.
                pendingHyphen = !result.isEmpty
            } else if character.isASCII, character.isLetter || character.isNumber {
                if pendingHyphen {
                    result.append("-")
                    pendingHyphen = false
                }
                result.append(character)
            }
        }
        let capped = String(result.prefix(63))
        let trimmed = capped.hasSuffix("-") ? String(capped.dropLast()) : capped
        return trimmed.isEmpty ? nil : trimmed
    }
}
