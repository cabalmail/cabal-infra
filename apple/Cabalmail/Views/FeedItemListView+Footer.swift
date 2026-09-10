import SwiftUI
import CabalmailKit

// The list's footer: the empty states, the "Search older items" offer when a
// search finds nothing cached, and "Load older items". A sibling extension
// so the primary view body stays under SwiftLint's `type_body_length` cap,
// like `MessageListView` and its `+Filter` / `+Rows` files.
extension FeedItemListView {
    @ViewBuilder
    func listFooter(_ model: FeedItemListViewModel) -> some View {
            if model.items.isEmpty {
                ContentUnavailableView(
                    emptyTitle(model),
                    systemImage: "dot.radiowaves.up.forward",
                    description: Text(emptyDescription(model))
                )
                .listRowSeparator(.hidden)
                // The index only knows what is cached: offer to pull another
                // page of history and search it too.
                if !model.searchQuery.isEmpty, model.canLoadOlder {
                    Button {
                        Task { await model.loadOlder() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isLoadingOlder { ProgressView() } else { Text("Search older items") }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ColorTokens.accentForestFg)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("feed.searchOlder")
                }
            }
            if model.canLoadOlder && model.searchQuery.isEmpty {
                Button {
                    Task { await model.loadOlder() }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoadingOlder { ProgressView() } else { Text("Load older items") }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(ColorTokens.accentForestFg)
                .accessibilityIdentifier("feed.loadOlder")
            }
    }

    func emptyTitle(_ model: FeedItemListViewModel) -> String {
        if !model.searchQuery.isEmpty { return "No matches" }
        switch model.filter {
        case .all: return model.isSyncing ? "Fetching…" : "No items yet"
        case .unread: return "All caught up"
        case .favorite: return "No favorites"
        }
    }

    func emptyDescription(_ model: FeedItemListViewModel) -> String {
        if !model.searchQuery.isEmpty { return "Nothing cached for this feed matches." }
        switch model.filter {
        case .all: return "New items appear here as the feed is fetched."
        case .unread: return "Every item here has been read."
        case .favorite: return "Swipe an item or use its menu to favorite it."
        }
    }
}
