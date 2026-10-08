import SwiftUI

#if os(macOS)
/// Disabled stand-ins for the feed reader's toolbar buttons, shown while a
/// feed scope is selected but no item is open: the wide bar's fullest set
/// (`FeedReaderToolbarLayout.standIns`), in its order, so a button never
/// moves under the pointer when an item opens. The mail pane's
/// `EmptyDetailToolbar` reserves the mail reader's eleven slots for the same
/// reason; in feed scope those would be the wrong set, and the first item
/// opened would swap eleven greyed mail buttons for six feed ones.
struct EmptyFeedDetailToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ForEach(FeedReaderToolbarLayout.standIns, id: \.self) { action in
            ToolbarItem { standIn(for: action) }
        }
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
