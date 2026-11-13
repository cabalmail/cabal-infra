import Foundation

/// One entry in the user's flag palette
/// (`docs/1.x/rules-composition-and-custom-flags-plan.md`, Phase 3).
///
/// `slot` is one of the fixed IMAP keyword atoms `cabal-flag-01` ...
/// `cabal-flag-20` (decision 4): the mailstore only ever sees slot atoms,
/// and everything user-visible — label, color, order — is palette
/// metadata riding synced preferences. Renaming a flag touches zero
/// messages; deleting and re-creating reuses the slot and never mints a
/// new keyword.
///
/// One entry is not a keyword: `FlagPalette.systemSlot` stands for the
/// system `\Flagged` flag (`docs/1.x/unified-flags-plan.md`), which every
/// mailbox has and no palette edit can remove.
///
/// `color` stays a raw string rather than an enum on purpose: the server
/// enforces the fixed color set, and a color this build doesn't know (from
/// a newer client against a newer server) must round-trip unchanged
/// instead of being coerced and re-pushed. `FlagPalette.colors` is the set
/// the UI offers.
///
/// An entry is in the palette or it is not: there is no way to switch one
/// off. Older builds wrote an `enabled` key on every entry, and a stored
/// palette may still carry it. It is skipped on decode, like any key this
/// type has no field for, and never written; the server stops accepting it
/// in 2.0 (`docs/2.x/flag-palette-enabled-removal.md`).
public struct FlagPaletteEntry: Codable, Hashable, Sendable, Identifiable {
    public var slot: String
    public var label: String
    public var color: String

    public var id: String { slot }

    public init(slot: String, label: String, color: String) {
        self.slot = slot
        self.label = label
        self.color = color
    }
}

/// Wire marshalling and limits for the flag palette.
///
/// The palette rides the synced-preferences `app` map as a JSON-encoded
/// STRING under the `flag_palette` key — deliberately not a nested object,
/// because every shipped client decodes the app map as string-to-string
/// and a nested value would silently break their whole preferences pull.
/// The limits mirror `lambda/api/set_preferences/function.py`, which
/// enforces them all and refuses the whole map over one. The Kit holds a
/// name to its own limit as well (`ServerTextRules.flagLabel(_:)`,
/// applied by `Preferences`), so the app sends no name the server refuses;
/// the slots, the count of entries and the colors are the server's alone
/// to check.
public enum FlagPalette {
    /// The 20 keyword slots plus the system flag's entry.
    public static let maxEntries = 21
    public static let maxLabelLength = 32
    /// Every assignable keyword slot atom, in order. `systemSlot` is not
    /// one of them: it is never handed out and never runs out.
    public static let slots: [String] = (1...20).map { String(format: "cabal-flag-%02d", $0) }
    /// The palette slot of the system `\Flagged` flag: the IMAP atom
    /// itself rather than a made-up id, so `Flag(wireValue:)` turns any
    /// entry's slot into the flag it sets, and a build that predates the
    /// entry sets the system flag when the user picks it
    /// (`docs/1.x/unified-flags-plan.md`, decision 1).
    public static let systemSlot = Flag.flagged.wireValue
    /// The system flag's entry for a palette that stores none (decision
    /// 2). Yellow shares its hue with the `flagged.fg` token, so the flag
    /// looks as it did before it had an entry.
    public static let defaultSystemEntry = FlagPaletteEntry(
        slot: systemSlot, label: "Flagged", color: "yellow"
    )
    /// The fixed color vocabulary `set_preferences` accepts, in the order
    /// the pickers present it.
    public static let colors = [
        "red", "orange", "yellow", "green", "teal",
        "blue", "indigo", "purple", "pink", "gray",
    ]

    /// Decodes the wire string, or nil when it doesn't parse — callers keep
    /// their current palette rather than adopting garbage.
    public static func decode(_ wire: String) -> [FlagPaletteEntry]? {
        guard let data = wire.data(using: .utf8),
              let entries = try? JSONDecoder().decode([FlagPaletteEntry].self, from: data)
        else { return nil }
        return entries
    }

    /// Encodes for the wire in the server's canonical shape: compact,
    /// object keys sorted, array order preserved (array order IS the
    /// display order).
    public static func encode(_ entries: [FlagPaletteEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(entries),
              let wire = String(data: data, encoding: .utf8)
        else { return "[]" }
        return wire
    }

    /// The lowest keyword slot not yet used, or nil once all 20 are.
    public static func firstFreeSlot(in entries: [FlagPaletteEntry]) -> String? {
        let used = Set(entries.map(\.slot))
        return slots.first { !used.contains($0) }
    }

    /// The keyword slots present in a message's flag set, in fixed slot
    /// order. The system flag is not among them; `slots(in:palette:)` is
    /// the form that includes it and follows the palette's order.
    public static func slots(in flags: Set<Flag>) -> [String] {
        slots.filter { flags.contains(.keyword($0)) }
    }
}

// MARK: - The system flag's entry

/// The system flag as a palette entry (`docs/1.x/unified-flags-plan.md`).
///
/// Two palettes are in play. The *stored* palette is what
/// `Preferences.flagPalette` holds and what rides the wire. The
/// *effective* palette is what the user sees: the stored one, with the
/// system flag's entry supplied when the stored one has none. The entry is
/// only stored once the user has changed it, so the palette of a user who
/// never touches it stays as it was on every device and on the server.
extension FlagPalette {
    /// The palette as the user sees it: `stored`, led by
    /// `defaultSystemEntry` when it has no entry for the system flag.
    public static func effective(_ stored: [FlagPaletteEntry]) -> [FlagPaletteEntry] {
        stored.contains { $0.slot == systemSlot } ? stored : [defaultSystemEntry] + stored
    }

    /// The keyword entries alone, in palette order: what a picker offers
    /// beside a control that already toggles the system flag, and the only
    /// slots a rule's `flags` list may name.
    public static func keywordEntries(in stored: [FlagPaletteEntry]) -> [FlagPaletteEntry] {
        stored.filter { $0.slot != systemSlot }
    }

    /// The flag the one-gesture toggles act on (the swipe, the shortcut,
    /// the reader's button): the first entry of the effective palette.
    /// There always is one, since the effective palette always holds the
    /// system flag's entry.
    public static func defaultEntry(in stored: [FlagPaletteEntry]) -> FlagPaletteEntry {
        effective(stored).first ?? defaultSystemEntry
    }

    /// What to store after the user edits the effective palette.
    ///
    /// The system entry is left out when it is still exactly what
    /// `effective(_:)` would supply — the default entry, in first place —
    /// and `previous`, the stored palette the edit started from, had none.
    /// Once stored it stays, even if a later edit puts it back to the
    /// default: only `resettingSystemEntry(in:)` removes it. So saving an
    /// edit to some other flag never adds the entry, and a user who has
    /// arranged the palette keeps the arrangement.
    public static func stored(
        afterEditing edited: [FlagPaletteEntry],
        from previous: [FlagPaletteEntry]
    ) -> [FlagPaletteEntry] {
        let wasStored = previous.contains { $0.slot == systemSlot }
        guard !wasStored, edited.first == defaultSystemEntry else { return edited }
        return Array(edited.dropFirst())
    }

    /// "Reset to default" for the system entry, which cannot be deleted:
    /// drops the stored entry so `effective(_:)` supplies the default
    /// again, in first place.
    public static func resettingSystemEntry(in stored: [FlagPaletteEntry]) -> [FlagPaletteEntry] {
        stored.filter { $0.slot != systemSlot }
    }

    /// The palette slots a message carries, in the order dots and chips
    /// draw them: the effective palette's order, the system flag included.
    /// A keyword slot the message carries but the palette no longer lists
    /// (a deleted flag's) comes last, in slot order,
    /// so its tag can still be shown and removed.
    public static func slots(in flags: Set<Flag>, palette stored: [FlagPaletteEntry]) -> [String] {
        let listed = effective(stored).map(\.slot).filter { flags.contains(Flag(wireValue: $0)) }
        let unlisted = slots(in: flags).filter { !listed.contains($0) }
        return listed + unlisted
    }
}
