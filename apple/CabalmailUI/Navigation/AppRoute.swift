import CabalmailKit

/// Where one main window is, by ID only: the section it is in; in mail, the
/// folder and the open message; in feeds, the list and the open item.
///
/// `SceneNavigator` keeps the route beside the resolved values the views
/// still take (`Folder`, `Envelope`, `RssItem`). A layout swap — an iPhone
/// Duo fold, an iPad window narrowing across the size-class line — builds a
/// new view tree that renders the route, so the window keeps its place.
/// `Codable` so a window can later restore it from scene storage; nothing
/// persists it yet.
///
/// What is deliberately not here: the compact tab and column (layout, kept on
/// the navigator beside the route), search (its results are not meant to
/// outlive the process), and the list selection.
struct AppRoute: Codable, Hashable, Sendable {
    var section: ResumeSession.Section
    var mail = Mail()
    var feeds = Feeds()

    struct Mail: Codable, Hashable, Sendable {
        var folderPath: String?
        /// The open message, when it is the folder's own. A search result
        /// open on the reader is search's, not the route's.
        var message: MessageRef?
    }

    struct Feeds: Codable, Hashable, Sendable {
        var scope: RssItemScope?
        var item: Item?
    }

    /// A feed item by the pair the resume session stores.
    struct Item: Codable, Hashable, Sendable {
        var feedID: String
        var sortKey: String

        init(_ item: RssItem) {
            feedID = item.feedId
            sortKey = item.sortKey
        }
    }
}
