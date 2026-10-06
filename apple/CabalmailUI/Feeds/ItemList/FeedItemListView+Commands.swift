import SwiftUI
import CabalmailKit

// The Feeds menu's item commands (cross-media plan, Phase 1): ⌘T, ⌘⇧8 and
// ⌥⌘T arriving through `AppState.requestFeedCommand`, answered by the
// mounted item list. A sibling extension so the primary body stays under
// SwiftLint's `type_body_length` cap.
extension FeedItemListView {
    /// The toggles act on the selected row, else the open item — the rule
    /// `MessageMenuAvailability.canActOnSelection` states for mail. The feed
    /// list is single-selection and its selection is the open item (the
    /// reader is bound to it, and on compact it is what pushed the reader),
    /// so one value answers both; the reader picks the change up from the
    /// state bus. Mark all read goes through the same confirmation the
    /// toolbar button uses. The catalog commands are the sidebar's.
    func handleFeedCommand(_ command: FeedCommand, model: FeedItemListViewModel) {
        switch command {
        case .toggleRead:
            guard let item = selection else { return }
            Task { await model.setRead(item, !item.isRead) }
        case .toggleFlag:
            guard let item = selection else { return }
            Task { await model.setFavorite(item, !item.isFavorite) }
        case .markAllRead:
            confirmMarkAllRead = true
        case .subscribe, .newFolder, .importOpml, .exportOpml, .refresh:
            break
        }
    }
}
