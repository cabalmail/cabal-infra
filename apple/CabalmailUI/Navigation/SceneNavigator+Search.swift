import Foundation
import CabalmailKit

// The window's search across both media: what is in front of it when it
// begins, which is the scope it opens on (flags-and-cross-media.md,
// decision 17). The search model and the place are members of
// `SceneNavigator` itself; the layout hand-off's side is beside
// `ShellHandOff`'s other decisions there.
extension SceneNavigator {
    /// The tab bar's pick, for the tab layouts' shells. Opening Search from
    /// another tab notes that tab as what the search is in front of: Mail
    /// (or visionOS's Folders), Feeds, or neither. A switch the app makes
    /// itself (a layout change carrying a search across) does not come
    /// through here, and that search keeps the scope it had.
    func selectTab(_ tab: CompactTab) {
        if tab == .search, compactTab != .search {
            searchPlace.noteFront(SearchFront.tab(compactTab, showsFlagged: flaggedIsInFront))
        }
        showTab(tab)
    }
}
