import Foundation
import CabalmailKit

/// Advancement logic for the detail-view dispose flow. Lives in its own
/// file so `MessageListViewModel.swift` stays under SwiftLint's file
/// length cap; kept `@MainActor` to match the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// The envelope to select after `current` is disposed from the detail
    /// view, per the user's after-dispose preference. Returns nil when no
    /// candidate exists — the caller then clears selection. Call before
    /// pruning `current`: every policy walks from its list index.
    func advanceTarget(after current: Envelope, following advance: DisposeAdvance) -> Envelope? {
        switch advance {
        case .next:           return nextEnvelope(after: current)
        case .nextUnread:     return nextUnreadEnvelope(after: current)
        case .previousUnread: return previousUnreadEnvelope(before: current)
        case .firstUnread:    return firstUnreadEnvelope(excluding: current)
        }
    }

    /// The envelope to select after `current` is marked read from the detail
    /// view, per the user's after-mark-read preference. Returns nil for
    /// `.stay` and when no candidate exists — the caller then leaves the
    /// selection where it is (the marked row is still in the list, so nil
    /// never clears it). The walks don't consult `current`'s own read state,
    /// so this is safe to call before or after its optimistic `\Seen` flip
    /// lands. Named apart from `advanceTarget` because an overload on the
    /// advance type alone makes shared members (`.nextUnread` et al.)
    /// ambiguous at contextual-member call sites.
    func markReadAdvanceTarget(after current: Envelope, following advance: MarkReadAdvance) -> Envelope? {
        switch advance {
        case .stay:           return nil
        case .nextUnread:     return nextUnreadEnvelope(after: current)
        case .previousUnread: return previousUnreadEnvelope(before: current)
        case .firstUnread:    return firstUnreadEnvelope(excluding: current)
        }
    }

    /// The envelope after `current` in the current list ordering, read or
    /// not. Disposing the bottom row falls back to the row above it — the
    /// new bottom — rather than bouncing back to the list.
    func nextEnvelope(after current: Envelope) -> Envelope? {
        guard let index = envelopes.firstIndex(where: { $0.uid == current.uid }) else {
            return envelopes.first
        }
        if index + 1 < envelopes.count {
            return envelopes[index + 1]
        }
        return index > 0 ? envelopes[index - 1] : nil
    }

    /// The nearest unread envelope below `current` in the current list
    /// ordering (UID descending, i.e. older). Falls back to the nearest
    /// unread above (newer) so a user archiving the oldest unread doesn't
    /// bounce back to the list when unread messages remain further up.
    /// Returns nil when no other unread messages exist in this folder.
    func nextUnreadEnvelope(after current: Envelope) -> Envelope? {
        guard let index = envelopes.firstIndex(where: { $0.uid == current.uid }) else {
            return envelopes.first { !$0.flags.contains(.seen) }
        }
        if let below = envelopes.dropFirst(index + 1)
            .first(where: { !$0.flags.contains(.seen) }) {
            return below
        }
        return envelopes.prefix(index).reversed()
            .first(where: { !$0.flags.contains(.seen) })
    }

    /// Mirror of `nextUnreadEnvelope`: the nearest unread above (newer),
    /// falling back to the nearest unread below.
    func previousUnreadEnvelope(before current: Envelope) -> Envelope? {
        guard let index = envelopes.firstIndex(where: { $0.uid == current.uid }) else {
            return envelopes.first { !$0.flags.contains(.seen) }
        }
        if let above = envelopes.prefix(index).reversed()
            .first(where: { !$0.flags.contains(.seen) }) {
            return above
        }
        return envelopes.dropFirst(index + 1)
            .first(where: { !$0.flags.contains(.seen) })
    }

    /// The topmost unread in the current ordering. Skips the disposed
    /// message itself — its optimistic `\Seen` mark travels on a separate
    /// signal, so its row may still read as unread here.
    func firstUnreadEnvelope(excluding current: Envelope) -> Envelope? {
        envelopes.first { $0.uid != current.uid && !$0.flags.contains(.seen) }
    }
}
