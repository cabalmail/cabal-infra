import SwiftUI

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
