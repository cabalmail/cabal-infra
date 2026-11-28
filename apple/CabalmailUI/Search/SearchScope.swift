import Foundation

/// Which media a search covers (`docs/1.x/cross-media-ux-plan.md`, Phase 5):
/// the control at the top of the results.
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case all, mail, feeds

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .mail: return "Mail"
        case .feeds: return "Feeds"
        }
    }

    /// Whether the scope runs the server's mail search.
    var includesMail: Bool { self != .feeds }
    /// Whether the scope reads the feed store.
    var includesFeeds: Bool { self != .mail }
}

/// The scope a window's search is on, and the medium in front of it.
///
/// A search opens on the medium in front, and on All where that is
/// ambiguous (flags-and-cross-media.md, decision 17). A pick of the control
/// lasts until that search is cleared and is stored nowhere; the next
/// search opens on the medium in front again.
///
/// The scope is read, not written: with no search under way it is whatever
/// is in front now, so a window that says what is in front only before a
/// search begins, or only after one has ended, is answered the same. A
/// search under way holds the scope it began on, or a pick since.
struct SearchScopeState: Equatable {
    /// What a search begun now would open on.
    private(set) var front: SearchScope = .all
    /// The scope the search under way holds: what was in front when it
    /// began, once something else has come in front, or a pick. Nil with
    /// no search, and while a search is still over what it began over.
    private var held: SearchScope?

    var scope: SearchScope { held ?? front }

    /// The window says what is in front of its search: the list the wide
    /// layouts' field stands over, or the tab the Search tab was opened
    /// from. A search under way keeps the scope it has; with none, the
    /// scope follows.
    mutating func noteFront(_ front: SearchScope, searchInProgress: Bool) {
        if searchInProgress, held == nil { held = self.front }
        self.front = front
    }

    /// A pick of the control.
    mutating func pick(_ scope: SearchScope) {
        held = scope
    }

    /// The search was cleared: the pick goes with it.
    mutating func searchEnded() {
        held = nil
    }

    /// The window changed layout shell. A search it carries keeps its
    /// scope; what was in front of the old layout says nothing of the new
    /// one, so the next search opens on All until the new layout says.
    mutating func layoutChanged(searchInProgress: Bool) {
        noteFront(.all, searchInProgress: searchInProgress)
    }
}

/// The medium in front of a window, as the scope a search begun there opens
/// on. Pure, so each layout's answer is stated once.
enum SearchFront {
    /// On the wide layouts the search field stands over the list column:
    /// a folder's list is mail, a feed list is feeds, and the Flagged view,
    /// which lists both, or no list at all, is All.
    static func wide(showsFlagged: Bool, hasFeedList: Bool, hasFolder: Bool) -> SearchScope {
        if showsFlagged { return .all }
        if hasFeedList { return .feeds }
        return hasFolder ? .mail : .all
    }

    /// On the tab layouts Search is a tab of its own, opened from another:
    /// the Mail tab (and visionOS's Folders tab, which is mail's folder
    /// list) is mail, the Feeds tab is feeds, and Addresses, Settings or
    /// the Flagged view in either tab is All.
    static func tab(_ tab: CompactTab, showsFlagged: Bool) -> SearchScope {
        if showsFlagged { return .all }
        switch tab {
        case .mail, .folders: return .mail
        case .feeds: return .feeds
        case .addresses, .settings, .search: return .all
        }
    }
}
