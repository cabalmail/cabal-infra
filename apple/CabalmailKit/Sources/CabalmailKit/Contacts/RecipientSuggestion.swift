import Foundation

/// One row offered by the compose recipient autocomplete. A single
/// `CNContact` with three email addresses unfolds into three
/// `RecipientSuggestion` rows so the user can pick the address they
/// actually want.
public struct RecipientSuggestion: Sendable, Hashable, Identifiable {
    public let name: String?
    public let email: String

    public init(name: String?, email: String) {
        self.name = name
        self.email = email
    }

    /// Stable identity per (name, email) tuple — duplicates are filtered
    /// at the source so two contacts that legitimately share an email
    /// surface only once.
    public var id: String { "\(name ?? "")|\(email.lowercased())" }

    /// `"Name" <addr@host>` if a name is present, else the bare email.
    /// Mirrors `EmailAddress.formatted` so a chosen suggestion serializes
    /// the same way a hand-typed `Name <addr>` would.
    public var formatted: String {
        guard let name, !name.isEmpty else { return email }
        return "\"\(name)\" <\(email)>"
    }
}

/// Pure functions for compose autocomplete: trailing-token parsing,
/// fuzzy ranking, and post-tap text rewriting. Lives in CabalmailKit
/// so it stays testable without standing up SwiftUI.
public enum RecipientAutocomplete {

    /// Pulls the active token off the end of a comma-separated recipient
    /// list. Returns the trimmed final segment, or an empty string when
    /// the user has just typed a comma (the suggestion list should hide).
    public static func trailingToken(in text: String) -> String {
        guard let lastComma = text.lastIndex(of: ",") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let after = text.index(after: lastComma)
        return String(text[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the new field text after the user taps a suggestion: the
    /// active trailing token is replaced with the formatted recipient
    /// and a `", "` separator so the caret can continue into the next
    /// recipient without manual punctuation.
    public static func applying(
        suggestion: RecipientSuggestion,
        toFieldText text: String
    ) -> String {
        let suffix = "\(suggestion.formatted), "
        guard let lastComma = text.lastIndex(of: ",") else {
            return suffix
        }
        let head = text[...lastComma]
        // Preserve the user's "comma + (optional space)" spacing style
        // by appending a single space ourselves — `text[after(comma)...]`
        // is dropped entirely.
        return "\(head) \(suffix)"
    }

    /// Filters and ranks candidate suggestions against the user's
    /// in-progress token. Ranking tiers, highest first:
    ///   1. Name has a word that starts with the query (case-insensitive).
    ///   2. Email local part starts with the query.
    ///   3. Name or email contains the query as a substring.
    /// Within a tier the original order is preserved (stable sort).
    /// Returns at most `limit` results; empty query returns empty.
    public static func suggestions(
        for query: String,
        from candidates: [RecipientSuggestion],
        limit: Int = 5
    ) -> [RecipientSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = trimmed.lowercased()

        var nameWordHits: [RecipientSuggestion] = []
        var emailPrefixHits: [RecipientSuggestion] = []
        var substringHits: [RecipientSuggestion] = []

        for candidate in candidates {
            let lowerName = candidate.name?.lowercased() ?? ""
            let lowerEmail = candidate.email.lowercased()
            let localPart = lowerEmail.split(separator: "@", maxSplits: 1).first.map(String.init) ?? lowerEmail

            if nameHasWordPrefix(lowerName, needle: needle) {
                nameWordHits.append(candidate)
            } else if localPart.hasPrefix(needle) {
                emailPrefixHits.append(candidate)
            } else if lowerName.contains(needle) || lowerEmail.contains(needle) {
                substringHits.append(candidate)
            }
        }

        return Array((nameWordHits + emailPrefixHits + substringHits).prefix(limit))
    }

    private static func nameHasWordPrefix(_ name: String, needle: String) -> Bool {
        guard !name.isEmpty else { return false }
        if name.hasPrefix(needle) { return true }
        // Word-boundary match: whitespace, hyphen, apostrophe all count as
        // splitters so "Mary Ann Smith" suggests on "ann" and "Jean-Luc"
        // suggests on "luc". `CharacterSet` keeps this Unicode-aware.
        let splitters = CharacterSet(charactersIn: " -'")
        return name
            .components(separatedBy: splitters)
            .contains(where: { $0.hasPrefix(needle) })
    }
}
