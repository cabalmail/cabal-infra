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
    /// stored before this was kept, and while the window is on no such view.
    var smartView: SmartView?
    /// Which medium's place the smart view stands in: the Mail tab's or the
    /// Feeds tab's on the tab layouts, where each tab has a door to it, and
    /// the section the split was in on the wide ones. Nil with no smart
    /// view, and in a route that names none: the window's section then.
    var smartDoor: ResumeSession.Section?
    /// The message or feed item open in the smart view's reader.
    var smartItem: SmartItem?

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

    /// The item open in a smart view, in a stored shape of its own, as every
    /// stored format keeps one for an `ItemRef`: a message by its folder,
    /// UID and Message-ID, or a feed item by its feed and sort key.
    struct SmartItem: Codable, Hashable, Sendable {
        var folderPath: String?
        var messageUID: UInt32?
        var messageID: String?
        var feedID: String?
        var sortKey: String?

        init(_ ref: ItemRef) {
            switch ref {
            case .mail(let message):
                folderPath = message.folder
                messageUID = message.uid
                messageID = message.messageId
            case .feed(let feedID, let sortKey):
                self.feedID = feedID
                self.sortKey = sortKey
            }
        }

        /// The item this names; nil for a shape this build cannot read.
        var ref: ItemRef? {
            if let folderPath, let messageUID {
                return .mail(MessageRef(folder: folderPath, uid: messageUID, messageId: messageID))
            }
            if let feedID, let sortKey { return .feed(feedID: feedID, sortKey: sortKey) }
            return nil
        }
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
    /// The item open in the window: its smart view's while it is on one,
    /// else its section's, by the identity the two media share.
    var openItem: ItemRef? {
        if smartView != nil { return smartItem?.ref }
        switch section {
        case .mail: return mail.message.map(ItemRef.mail)
        case .feeds: return feeds.item.map { .feed(feedID: $0.feedID, sortKey: $0.sortKey) }
        }
    }

    /// Whether `restore` names the message open in the window's smart view.
    /// The resume session records that message as open in its own folder,
    /// which is where another device resumes it; in this window it is the
    /// view's to show, not that folder's list's to open. Matched on
    /// Message-ID where both carry one, else on UID, as a parked restore is.
    func smartViewHolds(_ restore: NavState) -> Bool {
        guard smartView != nil, let open = smartItem?.ref?.message, open.folder == restore.folder else { return false }
        if let waiting = restore.messageID, let held = open.messageId { return waiting == held }
        return restore.uid == open.uid
    }

    private enum StoredKeys: String, CodingKey {
        case section, mail, feeds, smartView, smartDoor, smartItem
    }

    /// Reads a stored route. The section and the two halves are required,
    /// as they always were. The smart view is not: a route stored before it
    /// was kept has none, and one that names a view this build does not know
    /// (a later build's) reads as none rather than failing the whole route,
    /// which would cost the window its folder and its open message too. Its
    /// door and its open item are read the same way, and only with a view.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKeys.self)
        section = try container.decode(ResumeSession.Section.self, forKey: .section)
        mail = try container.decode(Mail.self, forKey: .mail)
        feeds = try container.decode(Feeds.self, forKey: .feeds)
        let name = try? container.decodeIfPresent(String.self, forKey: .smartView)
        smartView = name.flatMap(SmartView.init(rawValue:))
        guard smartView != nil else { return }
        smartDoor = (try? container.decodeIfPresent(ResumeSession.Section.self, forKey: .smartDoor)) ?? nil
        smartItem = (try? container.decodeIfPresent(SmartItem.self, forKey: .smartItem)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StoredKeys.self)
        try container.encode(section, forKey: .section)
        try container.encode(mail, forKey: .mail)
        try container.encode(feeds, forKey: .feeds)
        try container.encodeIfPresent(smartView, forKey: .smartView)
        guard smartView != nil else { return }
        try container.encodeIfPresent(smartDoor, forKey: .smartDoor)
        try container.encodeIfPresent(smartItem, forKey: .smartItem)
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
