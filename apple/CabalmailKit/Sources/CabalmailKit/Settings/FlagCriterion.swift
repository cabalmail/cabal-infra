import Foundation

/// Which flagged items a list is narrowed to, in the palette's own terms:
/// the items carrying one flag, named by its palette slot, or the items
/// carrying any flag at all.
///
/// The built-in flag is a slot here like the others
/// (`FlagPalette.systemSlot`), so a filter names every flag one way. Each
/// store then says the criterion in its own words: a message search sends
/// `flagged`, `keyword` or `any_flag` (`SearchQuery`), and the feed store
/// reads the favorite bit or its `flags` column (`RssStore.ItemQuery`).
/// `matches` is the same rule over a flag set already in hand, for the rows
/// a list holds.
public enum FlagCriterion: Hashable, Sendable {
    /// Items carrying the flag in this palette slot. A string that is no
    /// slot of the palette matches nothing.
    case slot(String)
    /// Items carrying the built-in flag or any of the palette's keyword
    /// slots, one whose flag was deleted included: every item that draws a
    /// flag dot. Another keyword a message happens to carry (`$Forwarded`,
    /// `NonJunk`) is not a flag.
    case any

    /// The keyword slot this criterion names, when it names one: not the
    /// built-in flag's slot, and not a string that is no slot at all.
    public var keywordSlot: String? {
        guard case .slot(let slot) = self, FlagPalette.slots.contains(slot) else { return nil }
        return slot
    }

    /// Whether this is the built-in flag alone.
    public var isSystemFlag: Bool { self == .slot(FlagPalette.systemSlot) }

    /// Whether an item carrying `flags` passes.
    public func matches(_ flags: Set<Flag>) -> Bool {
        switch self {
        case .slot:
            if isSystemFlag { return flags.contains(.flagged) }
            return keywordSlot.map { flags.contains(.keyword($0)) } ?? false
        case .any:
            return flags.contains(.flagged) || FlagPalette.slots.contains { flags.contains(.keyword($0)) }
        }
    }
}
