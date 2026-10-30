import Foundation

/// The feed reader's toolbar actions. The raw value names the accessibility
/// identifier (`feed.reader.<raw>`), which the live bar and the probes read;
/// the macOS stand-ins add `.empty` (`feed.reader.empty.<raw>`).
enum FeedReaderAction: String, CaseIterable {
    case read, favorite, readerMode, remoteContent, article, more

    var identifier: String { "feed.reader.\(rawValue)" }

    /// Icon and label in the quiescent state (unread item, not flagged,
    /// reader styling available, feed content showing), which the macOS
    /// empty pane's stand-ins draw. The toggles read `ReaderToggleFace`, as
    /// the live buttons and the mail reader's stand-ins do.
    var quiescentSymbol: String {
        quiescentFace.systemImage
    }

    var quiescentTitle: String {
        quiescentFace.title
    }

    private var quiescentFace: (title: String, systemImage: String) {
        func toggle(_ face: ReaderToggleFace) -> (String, String) { (face.title, face.systemImage) }
        switch self {
        case .read:          return toggle(.read(isRead: false))
        case .favorite:      return toggle(.flag(isFlagged: false))
        case .readerMode:    return toggle(.readerView(isOn: false))
        case .remoteContent: return toggle(.remoteContent(isShown: false))
        case .article:       return ("Open article", "safari")
        case .more:          return ("More", "ellipsis.circle")
        }
    }
}

/// A row of one of the feed reader's menus.
enum FeedReaderMenuItem: Hashable {
    case readerMode, remoteContent, article, openInBrowser, shareLink, copyLink
}

/// A slot of the feed reader's own bar in a tall window: one of the
/// reader's actions, a page button or Compose. The page buttons and Compose
/// are not `FeedReaderAction`s: every other bar has them elsewhere, and the
/// macOS stand-ins draw every action.
enum FeedReaderBarSlot: Hashable {
    case action(FeedReaderAction)
    case page(ReaderPageRequest.Direction)
    case compose

    /// The slot's accessibility identifier.
    var identifier: String {
        switch self {
        case .action(let action): return action.identifier
        case .page(.upward): return "feed.reader.pageUp"
        case .page(.downward): return "feed.reader.pageDown"
        case .compose: return "feed.reader.compose"
        }
    }
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

    /// The feed reader's own bar where it fills a window taller than wide
    /// (`ReaderToolbarPolicy.placement`): Flag, Read, Page Up, Page Down,
    /// the View menu and Compose, the iPhone Duo spec's order for a tall
    /// window without the mail reader's Reply and Archive. The View menu
    /// stands in for the spec's Message menu, and keeps Open article. The
    /// list's bar, with its Compose, is behind the article there.
    static let tallBar: [FeedReaderBarSlot] = [
        .action(.favorite), .action(.read), .page(.upward), .page(.downward), .action(.more), .compose
    ]

    /// Whether the page buttons have anything to page: the publisher's page,
    /// or the feed's own content.
    static func pagingEnabled(showingArticle: Bool, hasFeedContent: Bool) -> Bool {
        showingArticle || hasFeedContent
    }

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

    /// The wide bar (macOS and visionOS), in drawn order: Read, Flag,
    /// Reader view and Remote content always; Open article and the More
    /// menu for an item with a link.
    ///
    /// Remote content keeps its slot while the publisher's page shows, and
    /// the bar disables it there (the page loads its own), rather than
    /// dropping it. It sits in the MIDDLE of the bar, so dropping it slid
    /// Open article and More 42 pt left under the pointer that had just
    /// pressed Open article, and a second click there opened More (#2206).
    /// Only the trailing pair ever comes and goes, where nothing follows it
    /// to shift.
    static func wideBar(hasArticle: Bool) -> [FeedReaderAction] {
        var actions: [FeedReaderAction] = [.read, .favorite, .readerMode, .remoteContent]
        if hasArticle { actions += [.article, .more] }
        return actions
    }

    /// Whether the Remote content control does anything: only over the
    /// feed's own content, and only when there is some. The publisher's page
    /// loads its own, so the control is disabled there, in the slot the wide
    /// bar keeps for it (#2206).
    static func remoteContentEnabled(showingArticle: Bool, hasFeedContent: Bool) -> Bool {
        hasFeedContent && !showingArticle
    }

    /// The More menu on the wide bar: the link rows.
    static let moreMenu: [FeedReaderMenuItem] = [.openInBrowser, .shareLink, .copyLink]

    /// Which kind of control the macOS wide bar draws for an action, the
    /// same rule `ReaderToolbarLayout.macControlShape` states for the mail
    /// reader and for the same reason: `EmptyFeedDetailToolbar` builds each
    /// stand-in from its live twin's kind so the slot is the right width
    /// and nothing shifts when an item opens (#2016). More is a pull-down
    /// menu (the link rows); every other action is a plain button.
    static func macControlShape(for action: FeedReaderAction) -> ReaderToolbarControlShape {
        switch action {
        case .more:
            return .menu
        case .read, .favorite, .readerMode, .remoteContent, .article:
            return .button
        }
    }

    /// The macOS empty pane's disabled stand-ins: the wide bar an item
    /// opened in this scope will draw, so a button never moves under the
    /// pointer when one opens (#2144).
    ///
    /// `hasArticle` is true, which reserves Open article and More at the
    /// trailing end: an item with no link drops them off the end, where
    /// nothing follows to shift. Whether the item opens on the publisher's
    /// page no longer matters, because the bar keeps Remote content's slot
    /// either way (#2206).
    static func standIns() -> [FeedReaderAction] {
        wideBar(hasArticle: true)
    }
}
