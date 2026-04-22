import Foundation
import CabalmailKit

/// Advancement logic for the detail-view archive flow. Lives in its own
/// file so `MessageListViewModel.swift` stays under SwiftLint's file
/// length cap; kept `@MainActor` to match the rest of the view model.
@MainActor
extension MessageListViewModel {
    /// Next envelope to select after `current` is disposed from the detail
    /// view. Returns the nearest unread envelope below `current` in the
    /// current list ordering (UID descending, i.e. older). Falls back to
    /// the nearest unread above (newer) so a user archiving the oldest
    /// unread doesn't bounce back to the list when unread messages remain
    /// further up. Returns nil when no other unread messages exist in this
    /// folder — the caller then clears selection.
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
}
