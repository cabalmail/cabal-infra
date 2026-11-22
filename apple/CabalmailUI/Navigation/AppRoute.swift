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
///
/// **Stored routes.** A route a build stored is read by the builds before and
/// after it. A key added here is optional and read leniently (`init(from:)`),
/// and a build that does not know a key ignores it, so a window restored by
/// another build opens on the part of the route that build understands.
struct AppRoute: Codable, Hashable, Sendable {
    var section: ResumeSession.Section
    var mail = Mail()
    var feeds = Feeds()
    /// The view of both media the window is on, in place of its mail folder
    /// or feed list, which keep their places beneath it. Nil in every route
    /// stored before this was kept, and in every route yet: no sidebar
    /// offers one (`SmartView`).
    var smartView: SmartView?

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

extension AppRoute {
    /// The item open in the window's section, by the identity the two media
    /// share.
    var openItem: ItemRef? {
        switch section {
        case .mail: return mail.message.map(ItemRef.mail)
        case .feeds: return feeds.item.map { .feed(feedID: $0.feedID, sortKey: $0.sortKey) }
        }
    }

    private enum StoredKeys: String, CodingKey {
        case section, mail, feeds, smartView
    }

    /// Reads a stored route. The section and the two halves are required,
    /// as they always were. The smart view is not: a route stored before it
    /// was kept has none, and one that names a view this build does not know
    /// (a later build's) reads as none rather than failing the whole route,
    /// which would cost the window its folder and its open message too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKeys.self)
        section = try container.decode(ResumeSession.Section.self, forKey: .section)
        mail = try container.decode(Mail.self, forKey: .mail)
        feeds = try container.decode(Feeds.self, forKey: .feeds)
        let name = try? container.decodeIfPresent(String.self, forKey: .smartView)
        smartView = name.flatMap(SmartView.init(rawValue:))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StoredKeys.self)
        try container.encode(section, forKey: .section)
        try container.encode(mail, forKey: .mail)
        try container.encode(feeds, forKey: .feeds)
        try container.encodeIfPresent(smartView, forKey: .smartView)
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
