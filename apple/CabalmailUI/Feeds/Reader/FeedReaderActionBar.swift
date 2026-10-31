import SwiftUI
import CabalmailKit

/// The feed reader's own bar where it fills a window taller than wide
/// (`FeedReaderToolbarLayout.tallBar`): Flag, Read, Page Up, Page Down, the
/// View menu and Compose, under the reading pane, in the chrome of the mail
/// reader's own bar (`MessageDetailView.readerActionBar`): a divider over a
/// row on the bar material. The reader's actions are `FeedReaderBarItem`s,
/// so their faces follow the model as they do in the navigation bar, which
/// draws none of them while this bar is up.
struct FeedReaderActionBar: View {
    let model: FeedItemDetailViewModel
    let isOffline: Bool

    @Environment(AppState.self) private var appState
    /// This window's identity, so Compose opens over this window.
    @Environment(\.commandWindowID) private var commandWindowID

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(FeedReaderToolbarLayout.tallBar.enumerated()), id: \.element) { index, slot in
                    if index > 0 { Spacer(minLength: 0) }
                    control(for: slot)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
            // The faces are `Label`s, titled for VoiceOver and the menus;
            // this is a plain row, not a toolbar, so icon-only is stated.
            .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private func control(for slot: FeedReaderBarSlot) -> some View {
        switch slot {
        case .action(let action):
            FeedReaderBarItem(action: action, model: model, isOffline: isOffline)
        case .page(let direction):
            Button {
                model.requestPage(direction)
            } label: {
                Label(direction == .upward ? "Page Up" : "Page Down",
                      systemImage: direction == .upward ? "chevron.up" : "chevron.down")
            }
            .disabled(!FeedReaderToolbarLayout.pagingEnabled(
                showingArticle: model.showingArticle, hasFeedContent: !model.item.bodyHtml.isEmpty
            ))
            .accessibilityIdentifier(slot.identifier)
        case .compose:
            // No ⌘N here: the item list's Compose holds it.
            Button {
                appState.compose.open(seed: ReplyBuilder.newDraft(), from: commandWindowID)
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier(slot.identifier)
        }
    }
}
