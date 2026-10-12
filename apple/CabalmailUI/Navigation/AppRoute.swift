import CabalmailKit

/// Where one main window is, by ID only: the section it is in; in mail, the
/// folder and the open message; in feeds, the list and the open item.
///
/// `SceneNavigator` keeps the route beside the resolved values the views
/// still take (`Folder`, `Envelope`, `RssItem`). A layout swap — an iPhone
/// Duo fold, an iPad window narrowing across the size-class line — builds a
/// new view tree that renders the route, so the window keeps its place.
/// `Codable` so the window's scene storage keeps it (`StoredRoute`), and a
/// window the system restores comes back where it was.
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

// The open message is stored by the fields the resume session keeps, as every
// stored format converts a `MessageRef` at its boundary: its folder is the
// route's own, and no UIDVALIDITY is stored.
extension AppRoute.Mail {
    private enum StoredKeys: String, CodingKey {
        case folderPath, messageUID, messageID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKeys.self)
        let folderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
        let uid = try container.decodeIfPresent(UInt32.self, forKey: .messageUID)
        let messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        self.init(folderPath: folderPath, message: nil)
        if let folderPath, let uid {
            message = MessageRef(folder: folderPath, uid: uid, messageId: messageID)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StoredKeys.self)
        try container.encodeIfPresent(folderPath, forKey: .folderPath)
        try container.encodeIfPresent(message?.uid, forKey: .messageUID)
        try container.encodeIfPresent(message?.messageId, forKey: .messageID)
    }
}
