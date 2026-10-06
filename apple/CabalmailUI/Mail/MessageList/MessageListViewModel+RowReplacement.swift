import Foundation
import CabalmailKit

// Row identity for the message list, and the one operation that changes it.
//
// A full swipe on a destructive action (Archive, Trash, Delete Forever) tells
// SwiftUI the row is being deleted. On 27 and later, where the rows sit in a
// `.swipeActionsContainer()` rather than a `List`, SwiftUI then holds the row
// slid open -- its content pushed off the edge, the full-width action button
// in its place -- until the row leaves the container, and it keeps that state
// on the container's row, which is the list's `ForEach` element.
//
// The index-addressed list never removes that element. When the envelope
// leaves, the slot just re-points at the next message, which inherits the held
// reveal: its content out of sight behind the swiped row's button, and a drag
// to close it taken by the navigation back gesture instead. A disposal that
// fails, and a Delete Forever the user cancels, leave the swiped message
// itself held open the same way.
//
// So when a swiped row's fate is settled, the list is handed a NEW row there:
// the slot's identity carries a generation, and `replaceRows(showing:)` bumps
// it, which SwiftUI reads as the old row leaving and a new one arriving -- the
// removal the destructive swipe announced. Taking the swipe actions off the
// row for a moment resets the reveal on iOS but only every other time on
// macOS; replacing the row is what holds on both. The filtered / search list
// is keyed by message rather than by slot, so its rows carry a per-message
// generation for the same purpose (`MessageRowIdentity`).

/// The identity of one row of the index-addressed message list: its absolute
/// position in the folder, plus a generation that changes only when the row
/// drawn there has to be replaced rather than updated (`replaceRows(showing:)`).
/// Everything else -- scrolling, paging, a refresh -- leaves the generation
/// alone, so slots keep their identity as they re-point.
struct MessageListSlot: Hashable {
    let index: Int
    let generation: Int
}

/// The virtualized list's `ForEach` data: one `MessageListSlot` per absolute
/// index in `0..<count`, built on access, so a folder of any size costs a count
/// and a small dictionary rather than an array of slots.
struct MessageListSlots: RandomAccessCollection {
    let count: Int
    fileprivate let generations: [Int: Int]

    var startIndex: Int { 0 }
    var endIndex: Int { count }

    subscript(position: Int) -> MessageListSlot {
        MessageListSlot(index: position, generation: generations.isEmpty ? 0 : generations[position] ?? 0)
    }
}

@MainActor
extension MessageListViewModel {
    /// The slots of a list `count` rows long, for the virtualized `ForEach`.
    func rowSlots(count: Int) -> MessageListSlots {
        MessageListSlots(count: count, generations: slotGenerations)
    }

    /// The identity the virtualized list gives the row at `index`: what a
    /// `ScrollViewReader` has to be handed to scroll there.
    func rowSlot(at index: Int) -> MessageListSlot {
        MessageListSlot(index: index, generation: slotGenerations[index] ?? 0)
    }

    /// The absolute index `ref`'s message occupies, while it's loaded.
    func slotIndex(of ref: MessageRef) -> Int? {
        index(of: ref).map { Int(windowStart) + $0 }
    }

    /// Gives each message in `refs` a new row in place of the one it has now,
    /// in both list shapes -- and gives each slot in `slots` one too. Called
    /// when a row that a destructive full swipe may be holding open is settled:
    /// it leaves, or it stays. Harmless where nothing was held open: the row is
    /// rebuilt where it would otherwise have been updated. Call it while the
    /// messages are still in `envelopes`, or their slots can't be found.
    func replaceRows(showing refs: some Sequence<MessageRef>, alsoAt slots: [Int] = []) {
        var replaced = Set(slots)
        for ref in refs {
            rowGenerations[ref, default: 0] += 1
            if let slot = slotIndex(of: ref) { replaced.insert(slot) }
        }
        for slot in replaced {
            slotGenerations[slot, default: 0] += 1
        }
    }
}
