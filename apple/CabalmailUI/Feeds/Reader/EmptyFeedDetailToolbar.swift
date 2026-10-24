import SwiftUI

#if os(macOS)
/// Disabled stand-ins for the feed reader's toolbar buttons, shown while a
/// feed scope is selected but no item is open: the wide bar an item opened
/// in this scope will draw (`FeedReaderToolbarLayout.standIns`), in its
/// order, so a button never moves under the pointer when an item opens. The
/// mail pane's `EmptyDetailToolbar` reserves the mail reader's eleven slots
/// for the same reason; in feed scope those would be the wrong set, and the
/// first item opened would swap eleven greyed mail buttons for six feed
/// ones.
struct EmptyFeedDetailToolbar: ToolbarContent {
    /// Whether an item opened in this scope comes up on the publisher's
    /// page, which drops the Remote-content slot from the middle of the bar
    /// (#2144). The shell reads it from the scope's saved open mode
    /// (`FeedDetailPolicy.opensArticle(in:folders:subscriptions:)`).
    var showsArticle: Bool = false

    var body: some ToolbarContent {
        ForEach(FeedReaderToolbarLayout.standIns(showingArticle: showsArticle), id: \.self) { action in
            ToolbarItem { standIn(for: action) }
        }
    }

    private func standIn(for action: FeedReaderAction) -> some View {
        // Built as the kind of control its live twin is
        // (`FeedReaderToolbarLayout.macControlShape`): More is a menu, and a
        // plain-button stand-in for it is narrower than the menu that
        // replaces it, which moves every slot after it (#2016).
        ToolbarStandIn(
            title: action.quiescentTitle,
            symbol: action.quiescentSymbol,
            shape: FeedReaderToolbarLayout.macControlShape(for: action)
        )
        .accessibilityIdentifier("feed.reader.empty.\(action.rawValue)")
    }
}
#endif
