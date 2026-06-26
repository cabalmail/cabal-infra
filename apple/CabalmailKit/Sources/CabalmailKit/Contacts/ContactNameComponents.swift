import Foundation

/// Best-effort split of an RFC 5322 display phrase into given / middle /
/// family name parts, for pre-filling a new system contact.
///
/// The contract is deliberately conservative: it only returns a structured
/// split when the phrase reads like an ordinary personal name. Anything that
/// could be a "Last, First" inversion, an address fragment, or an
/// organization / mailing-list label returns `nil` so the caller leaves the
/// name fields empty rather than guessing wrong — the user still sees the
/// system contact editor and can type the name themselves.
public struct ContactNameComponents: Sendable, Equatable {
    public let given: String?
    public let middle: String?
    public let family: String?

    public init(given: String?, middle: String?, family: String?) {
        self.given = given
        self.middle = middle
        self.family = family
    }
}

extension ContactNameComponents {
    /// Parses `name` into components, or returns `nil` when the phrase is
    /// missing or too ambiguous to split confidently.
    ///
    /// Bails (returns `nil`) when the phrase:
    /// - is empty / whitespace,
    /// - contains a comma (`"Smith, John"` — inverted order, or a list),
    /// - contains `@` or a digit (an address fragment or junk), or
    /// - has more than four whitespace-separated tokens (almost always an
    ///   organization or mailing-list label, not a person).
    ///
    /// A single bare token is treated as a given name. Everything else is
    /// handed to `PersonNameComponentsFormatter`, whose locale-aware split
    /// fills given / middle / family.
    public static func parse(_ name: String?) -> ContactNameComponents? {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        if raw.contains(",") { return nil }
        if raw.contains("@") { return nil }
        if raw.contains(where: { $0.isNumber }) { return nil }

        let tokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count <= 4 else { return nil }

        if tokens.count == 1 {
            return ContactNameComponents(given: tokens[0], middle: nil, family: nil)
        }

        let formatter = PersonNameComponentsFormatter()
        guard let comps = formatter.personNameComponents(from: raw) else {
            return nil
        }
        var given = comps.givenName?.nonEmptyTrimmed
        var middle = comps.middleName?.nonEmptyTrimmed
        let family = comps.familyName?.nonEmptyTrimmed
        // The formatter occasionally parses a phrase into only a nickname
        // (or nothing usable); without a given or family name there's
        // nothing worth pre-filling, so leave it to the user.
        if given == nil, family == nil {
            return nil
        }
        // `PersonNameComponentsFormatter` lumps a compound given name
        // ("Mary Ann") into `givenName` rather than splitting out a middle
        // name. When there's a surname and no middle yet, peel the first
        // word of a multi-word given into `given` and the remainder into
        // `middle` so "Mary Ann Smith" -> given / middle / family. The
        // formatter's particle / suffix / initials handling (e.g.
        // "David Lopez-Carr", "J. R.") is preserved — single-word givens
        // are left untouched.
        if middle == nil, family != nil, let compound = given {
            let parts = compound.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                given = parts[0]
                middle = parts[1]
            }
        }
        return ContactNameComponents(given: given, middle: middle, family: family)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
