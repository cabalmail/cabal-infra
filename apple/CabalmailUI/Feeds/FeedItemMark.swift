import Foundation
import CabalmailKit

/// One change a feed control makes to an item: its read state, or one flag
/// of the palette set or cleared.
///
/// A flag is named by its palette slot, the built-in flag's included
/// (`FlagPalette.systemSlot`). On a feed item the built-in flag is the
/// favorite bit and a flag of the user's own is a slot in `RssItem.flags`,
/// two fields with two writes; this type is where that difference stops,
/// so a row, a reader and a flag menu name a flag one way, as they do for
/// a message.
enum FeedItemMark: Equatable, Sendable {
    case read(Bool)
    case flag(slot: String, isSet: Bool)
}

extension RssItem {
    /// The palette flags the item carries, the built-in flag among them:
    /// what its dots, its chips and its flag menus read, the feed's
    /// counterpart of a message's flag set.
    var paletteFlags: Set<Flag> {
        var carried = Set(flags.map(Flag.keyword))
        if isFavorite { carried.insert(.flagged) }
        return carried
    }

    /// Whether the item carries the flag in palette slot `slot`.
    func carries(slot: String) -> Bool {
        slot == FlagPalette.systemSlot ? isFavorite : flags.contains(slot)
    }

    /// Makes `mark` on this copy: what a control shows at once, ahead of
    /// the store's write.
    mutating func apply(_ mark: FeedItemMark) {
        switch mark {
        case .read(let isRead):
            self.isRead = isRead
        case .flag(FlagPalette.systemSlot, let isSet):
            isFavorite = isSet
        case .flag(let slot, let isSet):
            if isSet { flags.insert(slot) } else { flags.remove(slot) }
        }
    }

    /// Whether `stored`, the same item as the store holds it, differs from
    /// this copy in any mark a row or a reader draws.
    func marksDiffer(from stored: RssItem) -> Bool {
        isRead != stored.isRead || isFavorite != stored.isFavorite || flags != stored.flags
    }

    /// Takes the store's marks, leaving the rest of this copy as it is.
    mutating func takeMarks(from stored: RssItem) {
        isRead = stored.isRead
        isFavorite = stored.isFavorite
        flags = stored.flags
    }
}

extension RssSyncEngine {
    /// Writes one mark: the store first, then a push, as each of the
    /// engine's own setters does. The built-in flag goes to the favorite
    /// bit; any other slot is a custom flag, which the store refuses unless
    /// it is one of the palette's keyword slots.
    func write(_ mark: FeedItemMark, to item: RssItem) async throws {
        switch mark {
        case .read(let isRead):
            try await setRead(item, isRead)
        case .flag(FlagPalette.systemSlot, let isSet):
            try await setFavorite(item, isSet)
        case .flag(let slot, let isSet):
            try await setFlag(item, slot: slot, isSet)
        }
    }
}
