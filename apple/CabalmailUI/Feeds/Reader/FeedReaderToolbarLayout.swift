import Foundation

/// The feed reader's toolbar actions. The raw value names the accessibility
/// identifier (`feed.reader.<raw>`), which the live bar and the probes read;
/// the macOS stand-ins add `.empty` (`feed.reader.empty.<raw>`).
enum FeedReaderAction: String, CaseIterable {
    case read, favorite, readerMode, remoteContent, article, more

    var identifier: String { "feed.reader.\(rawValue)" }

    /// Icon and label in the quiescent state (unread item, not flagged,
    /// reader styling available, feed content showing).
    var quiescentSymbol: String {
        switch self {
        case .read:          return "envelope.open"
        case .favorite:      return "flag"
        case .readerMode:    return "doc.richtext"
        case .remoteContent: return "eye.slash"
        case .article:       return "safari"
        case .more:          return "ellipsis.circle"
        }
    }

    var quiescentTitle: String {
        switch self {
        case .read:          return "Mark as read"
        case .favorite:      return "Flag"
        case .readerMode:    return "Show reader view"
        case .remoteContent: return "Show remote content"
        case .article:       return "Open article"
        case .more:          return "More"
        }
    }
}

/// A row of one of the feed reader's menus.
enum FeedReaderMenuItem: Hashable {
    case readerMode, remoteContent, article, openInBrowser, shareLink, copyLink
}

/// Which feed reader actions each bar draws, in drawn order, and what its
/// menus carry. Pure, so the order the view draws, the macOS stand-ins and
/// the tests all read one list. The touch bar is held to
/// `ReaderToolbarPolicy`'s top-bar budget, and the policy's placement for
/// feeds, the system top bar, is what lets the reader's body run under the
/// tab bar on iPhone.
///
/// The bar takes one of two shapes, and the view picks the shape per
/// platform: the touch top bar on iPhone and iPad, where three items plus a
/// title fit and the rest ride the View menu, and the wide bar on macOS and
/// visionOS, where each action is its own item.
enum FeedReaderToolbarLayout {
    /// The touch top bar: Read, Flag, and the View menu, which carries the
    /// display and article controls (`viewMenu`). Inside
    /// `ReaderToolbarPolicy.topBarCapacity`.
    static let menuBar: [FeedReaderAction] = [.read, .favorite, .more]

    /// The View menu's rows on the touch bar, in sections a divider
    /// separates. Remote content only while the feed's own content shows
    /// (the publisher's page loads its own); the article rows only for an
    /// item with a link.
    static func viewMenu(showingArticle: Bool, hasArticle: Bool) -> [[FeedReaderMenuItem]] {
        var display: [FeedReaderMenuItem] = [.readerMode]
        if !showingArticle { display.append(.remoteContent) }
        guard hasArticle else { return [display] }
        return [display, [.article, .openInBrowser, .shareLink, .copyLink]]
    }

    /// The wide bar (macOS and visionOS), in drawn order: Read, Flag and
    /// Reader view always; Remote content while the feed's own content
    /// shows; Open article and the More menu for an item with a link.
    static func wideBar(showingArticle: Bool, hasArticle: Bool) -> [FeedReaderAction] {
        var actions: [FeedReaderAction] = [.read, .favorite, .readerMode]
        if !showingArticle { actions.append(.remoteContent) }
        if hasArticle { actions += [.article, .more] }
        return actions
    }

    /// The More menu on the wide bar: the link rows.
    static let moreMenu: [FeedReaderMenuItem] = [.openInBrowser, .shareLink, .copyLink]

    /// The macOS empty pane's disabled stand-ins: the wide bar of an item
    /// showing its feed content with an article link, which is its fullest
    /// set, so a button never moves under the pointer when an item opens.
    static var standIns: [FeedReaderAction] {
        wideBar(showingArticle: false, hasArticle: true)
    }
}
