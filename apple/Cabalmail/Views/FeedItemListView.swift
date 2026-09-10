import SwiftUI
import CabalmailKit

/// Item list for a feed scope (one subscription, a folder, or everything):
/// filter pills, the local page from `RssStore`, swipe read/favorite,
/// per-feed search, and "Load older". Selection is lifted to the parent so
/// the split view can bind the reader to it.
struct FeedItemListView: View {
    let scope: RssItemScope
    @Binding var selection: RssItem?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @State private var model: FeedItemListViewModel?
    @State private var title = "Feeds"

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                filterBar(model)
                itemList(model)
            } else {
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .toolbar {
            // New Message stays in the toolbar in feed scope, in the same
            // slot the mail list gives it, so switching between mail and
            // feeds never moves the primary action (macOS groups it with
            // Refresh for the same reason the mail list does).
            #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                composeButton
                if let model { refreshButton(model) }
            }
            #else
            ToolbarItem { composeButton }
            if let model { ToolbarItem { refreshButton(model) } }
            #endif
            if let model {
                ToolbarItem {
                    Button {
                        Task { await model.markAllRead() }
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                    }
                    .disabled(model.items.allSatisfy(\.isRead))
                    .accessibilityIdentifier("feed.markAllRead")
                }
            }
        }
        .task(id: scope) { await start() }
    }

    private var composeButton: some View {
        Button {
            appState.requestCompose(seed: ReplyBuilder.newDraft())
        } label: {
            Image(systemName: "square.and.pencil")
                .accessibilityLabel("New Message")
        }
        .keyboardShortcut("n", modifiers: .command)
    }

    private func refreshButton(_ model: FeedItemListViewModel) -> some View {
        Button {
            Task { await model.sync() }
        } label: {
            RefreshActivityIcon(isLoading: model.isSyncing)
                .accessibilityLabel("Refresh feed")
        }
        .disabled(model.isSyncing)
        .accessibilityIdentifier("feed.refresh")
    }

    private func start() async {
        guard let client = appState.client else { return }
        var subscription: RssSubscription?
        if case .subscription(let id) = scope {
            subscription = try? await client.rssStore?.subscription(id: id)
        }
        title = await scopeTitle(client: client, subscription: subscription)
        let model = FeedItemListViewModel(scope: scope, subscription: subscription, client: client,
                                          preferences: preferences)
        self.model = model
        await model.reload()
        await model.sync()
    }

    private func scopeTitle(client: CabalmailClient, subscription: RssSubscription?) async -> String {
        switch scope {
        case .all: return "All Feeds"
        case .subscription: return subscription?.displayTitle ?? "Feed"
        case .folder(let id):
            let folders = (try? await client.rssStore?.folders()) ?? []
            return folders.first { $0.folderId == id }?.name ?? "Folder"
        }
    }

    @ViewBuilder
    private func filterBar(_ model: FeedItemListViewModel) -> some View {
        @Bindable var model = model
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(RssItemFilter.allCases, id: \.self) { filter in
                    Button {
                        model.filter = filter
                    } label: {
                        Text(filterLabel(filter))
                            .font(.subheadline.weight(model.filter == filter ? .semibold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                model.filter == filter ? ColorTokens.accentForestFg.opacity(0.18) : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("feed.filter.\(filter.rawValue)")
                }
                Spacer()
                if model.canSearch {
                    Menu {
                        Picker("Order", selection: $model.ordering) {
                            Text("Newest first").tag(RssOrderingMode.newestFirst)
                            Text("Oldest first").tag(RssOrderingMode.oldestFirst)
                            Text("Newest day, oldest first within").tag(RssOrderingMode.newestDayOldestWithin)
                            Text("Oldest day, newest first within").tag(RssOrderingMode.oldestDayNewestWithin)
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .accessibilityLabel("Order")
                    }
                    .onChange(of: model.ordering) { _, _ in Task { await model.reload() } }
                }
            }
            if model.canSearch {
                TextField("Search this feed", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("feed.search")
            }
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(ColorTokens.dangerFg)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func filterLabel(_ filter: RssItemFilter) -> String {
        switch filter {
        case .all: return "All"
        case .unread: return "Unread"
        case .favorite: return "Favorites"
        }
    }

    @ViewBuilder
    private func itemList(_ model: FeedItemListViewModel) -> some View {
        List(selection: $selection) {
            ForEach(model.items) { item in
                itemRow(item, model: model)
            }
            listFooter(model)
        }
        .listStyle(.plain)
        .refreshable { await model.sync() }
        .onChange(of: selection) { previous, item in
            // A new item opening, not the same item refreshed below: a
            // reader-side "mark as unread" must not be undone on the spot.
            guard let item, item.id != previous?.id else { return }
            Task { await model.didOpen(item) }
        }
        // Rows are tagged by value, so a row patched in place (read, favorite)
        // stops matching the selected value and drops its highlight. Follow
        // the patch: same id, fresh state.
        .onChange(of: model.items) { _, items in
            guard let current = selection,
                  let fresh = items.first(where: { $0.id == current.id }),
                  fresh != current else { return }
            selection = fresh
        }
    }

    @ViewBuilder
    private func itemRow(_ item: RssItem, model: FeedItemListViewModel) -> some View {
        FeedItemRow(item: item,
                    feedName: model.subscription == nil ? model.feedName(for: item) : nil,
                    isPending: model.pendingIds.contains(item.id))
                    .tag(item)
                    .accessibilityIdentifier("feed.item.\(item.id)")
                    .onAppear {
                        if item.id == model.items.last?.id { Task { await model.loadMore() } }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            Task { await model.setRead(item, !item.isRead) }
                        } label: {
                            Label(item.isRead ? "Mark unread" : "Mark read",
                                  systemImage: item.isRead ? "envelope.badge" : "envelope.open")
                        }
                        .tint(ColorTokens.accentForestFg)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await model.setFavorite(item, !item.isFavorite) }
                        } label: {
                            Label(item.isFavorite ? "Unfavorite" : "Favorite",
                                  systemImage: item.isFavorite ? "star.slash" : "star")
                        }
                        .tint(ColorTokens.flaggedFill)
                    }
                    .contextMenu {
                        Button(item.isRead ? "Mark as unread" : "Mark as read") {
                            Task { await model.setRead(item, !item.isRead) }
                        }
                        Button(item.isFavorite ? "Remove favorite" : "Favorite") {
                            Task { await model.setFavorite(item, !item.isFavorite) }
                        }
                        if let url = URL(string: item.url) {
                            Link("Open in browser", destination: url)
                        }
                    }
    }
}

/// One item row: unread dot, title, feed name (in multi-feed scopes),
/// relative date, favorite star, and a "queued" mark while a state change
/// waits for the network.
struct FeedItemRow: View {
    let item: RssItem
    /// The feed's name, in multi-feed scopes; nil in a single feed's list.
    let feedName: String?
    let isPending: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isRead ? Color.clear : ColorTokens.accentForestFg)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(.body.weight(item.isRead ? .regular : .semibold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let feedName, !feedName.isEmpty {
                        Text(feedName)
                            .lineLimit(1)
                    }
                    Text(FeedItemDate.relative(item.publishedAt))
                    if isPending {
                        Image(systemName: "clock.arrow.circlepath")
                            .accessibilityLabel("Change queued")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(ColorTokens.flaggedFg)
                    .accessibilityLabel("Favorite")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(item.isRead ? "" : "Unread, ")\(item.title), \(FeedItemDate.relative(item.publishedAt))"
        )
    }
}

/// Date rendering for item rows and the reader header.
enum FeedItemDate {
    private static let iso = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func date(_ iso8601: String) -> Date? {
        iso.date(from: iso8601) ?? isoFractional.date(from: iso8601)
    }

    static func relative(_ iso8601: String) -> String {
        guard let date = date(iso8601) else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func absolute(_ iso8601: String) -> String {
        guard let date = date(iso8601) else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// The feed's name for a multi-feed list. The item itself only carries
    /// ids; the row shows the host of the item URL as the cheap, always-
    /// available stand-in until the list model resolves titles (5d).
}
