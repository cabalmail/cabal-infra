import SwiftUI
import CabalmailKit

/// One flag mark on a list row: the palette entry a flag on the item
/// resolves to, as the row draws it.
///
/// A value rather than a slot id so that what a row shows can be worked out
/// and tested away from the view: which flags, in which order, under which
/// names and colors.
struct FlagDotMark: Equatable, Identifiable {
    let slot: String
    /// The palette entry's label, or the slot id for a tag whose entry was
    /// deleted.
    let label: String
    /// The palette color name; empty for a deleted entry, which draws gray.
    let color: String

    var id: String { slot }

    /// The most marks a row draws. Rows have a fixed height, and a message
    /// can carry every flag in the palette.
    static let rowLimit = 4

    /// A message's marks: every palette flag it carries, the system flag
    /// included, in palette order (`FlagPalette.slots(in:palette:)`) and
    /// capped at `limit`. A flag whose entry was deleted is still drawn,
    /// like every tag that outlives being offered.
    static func marks(
        for flags: Set<Flag>,
        palette stored: [FlagPaletteEntry],
        limit: Int = rowLimit
    ) -> [FlagDotMark] {
        let entries = FlagPalette.effective(stored)
        return FlagPalette.slots(in: flags, palette: stored).prefix(limit).map { slot in
            let entry = entries.first { $0.slot == slot }
            return FlagDotMark(slot: slot, label: entry?.label ?? slot, color: entry?.color ?? "")
        }
    }

    /// A feed item's marks. A feed item has one flag, stored as its
    /// favorite bit, and it is the system flag: the mark takes the name and
    /// color of the palette's entry for it, as a flagged message's does.
    static func marks(isFlagged: Bool, palette stored: [FlagPaletteEntry]) -> [FlagDotMark] {
        marks(for: isFlagged ? [.flagged] : [], palette: stored)
    }
}

/// The flag marks on a mail row and a feed row: one color dot per mark,
/// laid out by the enclosing stack.
///
/// This is the only rendering a flag has on a row. The system flag draws
/// the same dot as a custom one, in its palette color, so the row shows one
/// kind of flag rather than a glyph for one and dots for the rest.
struct FlagDots: View {
    let marks: [FlagDotMark]

    var body: some View {
        ForEach(marks) { mark in
            Circle()
                .fill(FlagPaletteColor.color(for: mark.color))
                .frame(width: 8, height: 8)
                .accessibilityLabel(mark.label)
        }
    }
}
