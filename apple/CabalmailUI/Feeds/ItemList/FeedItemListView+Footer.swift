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
        case .favorite:
            return FeedListNarrowing.emptyTitle(pick: model.flagPick, name: flagPickName(model))
        }
    }

    func emptyDescription(_ model: FeedItemListViewModel) -> String {
        if !model.searchQuery.isEmpty { return "Nothing cached for this feed matches." }
        switch model.filter {
        case .all: return "New items appear here as the feed is fetched."
        case .unread: return "Every item here has been read."
        case .favorite:
            guard let pick = model.flagPick else {
                return Self.flaggedEmptyDescription(
                    defaultFlagIsBuiltIn: model.defaultFlag.slot == FlagPalette.systemSlot, flagName: feedFlagName
                )
            }
            return FeedListNarrowing.emptyDescription(
                pick: pick, name: flagPickName(model),
                swipeSetsIt: model.defaultFlag.slot == pick.keywordSlot,
                isInPalette: flagPalette.contains { $0.slot == pick.keywordSlot }
            )
        }
    }

    /// The picked flag's name, as the lit pill has it in full.
    private func flagPickName(_ model: FeedItemListViewModel) -> String {
        FlagFilterMenuPolicy.name(of: model.flagPick, palette: flagPalette)
    }

    /// Under the Flagged pill with nothing to show and no flag picked from
    /// its menu (a pick's words are `FeedListNarrowing.emptyDescription`).
    /// The pill then filters on the
    /// built-in flag; the swipe and the menu's first item set the default
    /// flag, which is that flag only until another is made the default.
    /// After that the Flags menu is the way to set the one this pill shows.
    nonisolated static func flaggedEmptyDescription(defaultFlagIsBuiltIn: Bool, flagName: String) -> String {
        defaultFlagIsBuiltIn
            ? "Swipe an item or use its menu to flag it."
            : "Use an item's Flags menu to mark it \(flagName)."
    }
}
