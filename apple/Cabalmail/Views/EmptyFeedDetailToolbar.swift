import SwiftUI

/// The feed reader's toolbar actions, in the order `FeedItemDetailView`
/// draws them. One list feeds both the live toolbar's identifiers and the
/// disabled stand-ins the empty pane reserves on macOS, so the two can't
/// drift and a button never moves under the pointer when an item opens.
enum FeedReaderAction: String, CaseIterable {
    case read, favorite, readerMode, remoteContent, article, more

    var identifier: String { "feed.reader.\(rawValue)" }

    /// Icon and label in the quiescent state (unread item, not a favorite,
    /// reader styling available, feed content showing).
    var quiescentSymbol: String {
        switch self {
        case .read:          return "envelope.open"
        case .favorite:      return "star"
        case .readerMode:    return "doc.richtext"
        case .remoteContent: return "eye.slash"
        case .article:       return "safari"
        case .more:          return "ellipsis.circle"
        }
    }

    var quiescentTitle: String {
        switch self {
        case .read:          return "Mark as read"
        case .favorite:      return "Favorite"
        case .readerMode:    return "Show reader view"
        case .remoteContent: return "Show remote content"
        case .article:       return "Open article"
        case .more:          return "More"
        }
    }
}

#if os(macOS)
/// Disabled stand-ins for the feed reader's six toolbar buttons, shown while
/// a feed scope is selected but no item is open. The mail pane's
/// `EmptyDetailToolbar` reserves the mail reader's eleven slots for the same
/// reason; in feed scope those would be the wrong set, and the first item
/// opened would swap eleven greyed mail buttons for six feed ones.
struct EmptyFeedDetailToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem { standIn(for: .read) }
        ToolbarItem { standIn(for: .favorite) }
        ToolbarItem { standIn(for: .readerMode) }
        ToolbarItem { standIn(for: .remoteContent) }
        ToolbarItem { standIn(for: .article) }
        ToolbarItem { standIn(for: .more) }
    }

    private func standIn(for action: FeedReaderAction) -> some View {
        Button {} label: {
            Label(action.quiescentTitle, systemImage: action.quiescentSymbol)
        }
        .disabled(true)
        .accessibilityIdentifier("feed.reader.empty.\(action.rawValue)")
    }
}
#endif
