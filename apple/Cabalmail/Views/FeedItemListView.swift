import SwiftUI
import CabalmailKit

/// Item list for a feed scope (one subscription, a folder, or everything):
/// filter pills, the local page from `RssStore`, swipe read/favorite,
/// per-feed search, and "Load older". Selection is lifted to the parent so
/// the split view can bind the reader to it.
struct FeedItemListView: View {
    let scope: RssItemScope
    @Binding var selection: RssItem?
    /// Fires when the user picks another scope from the scope-switch menu
    /// behind the list's title (see `+ScopeSwitch`). The parent owns the
    /// selection, so it applies the pick exactly as a sidebar tap would.
    var onSwitchScope: (RssItemScope) -> Void = { _ in }
    /// Reports the measured width of the macOS scope-switch menu in the
    /// column's toolbar section, for the host that sizes the global search
    /// field around it — the mail list's `onFolderMenuWidthChanged` twin.
    var onScopeMenuWidthChanged: (CGFloat) -> Void = { _ in }

    // `appState`, `title`, `folders`, `switchSubscriptions` and
    // `confirmMarkAllRead` are module-internal so the `+ScopeSwitch` and
    // `+Commands` siblings can reach them.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) private var preferences
    @State var model: FeedItemListViewModel?
    /// Gates for the launch restore — see `applyLaunchRestoreWhenReady`.
    @State private var hasAppeared = false
    @State private var initialLoadComplete = false
    @State var title = "Feeds"
    // Feed Settings (RSS plan, phase 5c) for a single-feed list: the most
    // discoverable path to a feed's settings on iPhone, where the sidebar
    // row's context menu is a long-press away.
    @State private var management: FeedManagementViewModel?
    @State private var actions = FeedManagementActions()
    /// The catalog, for the settings sheet's folder picker and the
    /// scope-switch menu's rows; read once per mount, like the mail list's
    /// `switchFolders` (the view is re-keyed per scope).
    @State var folders: [RssFolder] = []
    @State var switchSubscriptions: [RssSubscription] = []
    @State var confirmMarkAllRead = false

    var body: some View {
        feedScopeSwitchTitle(
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
        )
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
                    // Confirmed first: it sat beside Refresh with no way back,
                    // and a stray tap read a whole feed (2026-09-10).
                    Button {
                        confirmMarkAllRead = true
                    } label: {
                        Label("Mark all as read", systemImage: "envelope.open")
                    }
                    .disabled(model.items.allSatisfy(\.isRead))
                    .accessibilityIdentifier("feed.markAllRead")
                }
                if let subscription = model.subscription {
                    ToolbarItem {
                        Button {
                            actions.settings(for: subscription)
                        } label: {
                            Label("Feed settings", systemImage: "gearshape")
                        }
                        .disabled(management == nil)
                        .accessibilityIdentifier("feed.settings")
                    }
                }
            }
        }
        .feedManagementSheets(actions, management: management, folders: folders, selection: .constant(nil),
                              onSaved: { updated in title = updated.displayTitle })
        .confirmationDialog("Mark all items in \(title) as read?", isPresented: $confirmMarkAllRead,
                            titleVisibility: .visible) {
            Button("Mark All as Read") { Task { await model?.markAllRead() } }
        } message: {
            Text("Items you have not opened will be marked read too.")
        }
        .task(id: scope) {
            await start()
            initialLoadComplete = true
            applyLaunchRestoreWhenReady()
        }
        .onAppear {
            hasAppeared = true
            applyLaunchRestoreWhenReady()
        }
        // The Feeds menu's item chords (`+Commands`); the catalog commands
        // on the same tick are the sidebar's and are ignored here.
        .onChange(of: appState.feedCommandTick) { _, _ in
            guard let model, let command = appState.pendingFeedCommand else { return }
            handleFeedCommand(command, model: model)
        }
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
        var folder: RssFolder?
        switch scope {
        case .subscription(let id):
            subscription = try? await client.rssStore?.subscription(id: id)
        case .folder(let id):
            folder = try? await client.rssStore?.folder(id: id)
        case .all:
            break
        }
        title = scopeTitle(subscription: subscription, folder: folder)
        if subscription != nil {
            management = FeedManagementViewModel(client: client)
        }
        folders = (try? await client.rssStore?.folders()) ?? []
        switchSubscriptions = (try? await client.rssStore?.subscriptions()) ?? []
        let model = FeedItemListViewModel(scope: scope, subscription: subscription, folder: folder,
                                          client: client, preferences: preferences)
        self.model = model
        await model.reload()
        await model.sync()
    }

    private func scopeTitle(subscription: RssSubscription?, folder: RssFolder?) -> String {
        switch scope {
        case .all: return "All Feeds"
        case .subscription: return subscription?.displayTitle ?? "Feed"
        case .folder: return folder?.name ?? "Folder"
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
                        feedSwipeButton(model.swipeLeading, item: item, model: model)
                    }
                    .swipeActions(edge: .trailing) {
                        feedSwipeButton(model.swipeTrailing, item: item, model: model)
                    }
                    .contextMenu {
                        Button(item.isRead ? "Mark as unread" : "Mark as read") {
                            Task { await model.setRead(item, !item.isRead) }
                        }
                        Button(item.isFavorite ? "Unflag" : "Flag") {
                            Task { await model.setFavorite(item, !item.isFavorite) }
                        }
                        if let url = URL(string: item.url) {
                            Link("Open in browser", destination: url)
                        }
                    }
    }
}

extension FeedItemListView {
    /// The button a swipe edge bound to `action` reveals for `item`; nothing
    /// for a disabled edge. Read on every row build, so a change under
    /// Settings › Feeds takes effect at once.
    @ViewBuilder
    func feedSwipeButton(_ action: FeedSwipeAction, item: RssItem, model: FeedItemListViewModel) -> some View {
        switch action {
        case .toggleRead:
            Button {
                Task { await model.setRead(item, !item.isRead) }
            } label: {
                Label(item.isRead ? "Mark unread" : "Mark read",
                      systemImage: item.isRead ? "envelope.badge" : "envelope.open")
            }
            .tint(ColorTokens.accentForestFg)
            .accessibilityIdentifier("feed.swipe.toggleRead")
        case .toggleFavorite:
            // Same words, glyphs and tint as the mail list's flag swipe
            // (`toggleFlagSwipe`): one mark, one vocabulary across media.
            // The identifier keeps the wire name for the probes.
            Button {
                Task { await model.setFavorite(item, !item.isFavorite) }
            } label: {
                Label(item.isFavorite ? "Unflag" : "Flag",
                      systemImage: item.isFavorite ? "flag.slash" : "flag")
            }
            .tint(ColorTokens.flaggedFill)
            .accessibilityIdentifier("feed.swipe.toggleFavorite")
        case .disabled:
            EmptyView()
        }
    }
}

/// One item row: unread dot, title, the first line of the body (when it
/// has one), feed name (in multi-feed scopes), relative date, the flag
/// mark, and a "queued" mark while a state change waits for the network.
struct FeedItemRow: View {
    let item: RssItem
    /// The feed's name, in multi-feed scopes; nil in a single feed's list.
    let feedName: String?
    let isPending: Bool

    var body: some View {
        // Cheap enough to derive per render: the scan stops at the first
        // line of prose, not the end of the body (see `HTMLText.firstLine`).
        let snippet = HTMLText.firstLine(from: item.bodyHtml)
        let title = item.title.isEmpty ? "Untitled" : item.title
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(item.isRead ? Color.clear : ColorTokens.accentForestFg)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(item.isRead ? .regular : .semibold))
                    .lineLimit(2)
                if !snippet.isEmpty {
                    // One line, cut with an ellipsis where it outruns the
                    // column; an item with no prose keeps the two-line row.
                    Text(snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
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
                // The mail row's `\Flagged` indicator, glyph and tint.
                Image(systemName: "flag.fill")
                    .foregroundStyle(ColorTokens.flaggedFg)
                    .accessibilityLabel("Flagged")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [item.isRead ? "" : "Unread", title, snippet, FeedItemDate.relative(item.publishedAt)]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        )
    }
}

/// Date rendering for item rows and the reader header.
enum FeedItemDate {
    // `Date.ISO8601FormatStyle` rather than `ISO8601DateFormatter`: these are
    // hoisted to statics so a list full of rows does not build a parser per
    // row, and a static non-Sendable reference type is a concurrency-safety
    // error in the Swift 6 language mode (#1507). Foundation marks
    // `NSDateFormatter` `NS_SWIFT_SENDABLE` and pointedly does not mark
    // `NSISO8601DateFormatter`, so `nonisolated(unsafe)` here would assert
    // exactly what Apple declined to; the format style is a Sendable value
    // type, so the hoisting stays and the unsafety goes.
    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func date(_ iso8601: String) -> Date? {
        (try? iso.parse(iso8601)) ?? (try? isoFractional.parse(iso8601))
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

// MARK: - Launch restore

// Same-file extension so the primary struct body stays under SwiftLint's
// `type_body_length` cap; `private` state stays reachable from here.
extension FeedItemListView {
    /// Selects the item the resume session parked for this scope — once this
    /// list is on screen and has loaded. Selecting it any earlier pushes the
    /// reader in the same update as the list, and on a compact stack the
    /// reader UIKit then shows is not the one SwiftUI runs `onAppear` / `task`
    /// for: it never builds its model and sits on a spinner until backed out
    /// of (#1664, reproduced on the iOS 27.1 simulator — the instance that
    /// logged its hooks was never the visible one). Selecting before the rows
    /// exist loses the selection instead. Whichever gate closes last applies
    /// it; `consumeFeedItemRestore` makes the two call sites idempotent. The
    /// loaded row is preferred so the highlight matches; an item outside the
    /// loaded window still opens, as it always has.
    private func applyLaunchRestoreWhenReady() {
        guard hasAppeared, initialLoadComplete, selection == nil,
              let restored = appState.navCoordinator?.consumeFeedItemRestore(for: scope)
        else { return }
        selection = model?.items.first { $0.id == restored.id } ?? restored
    }
}
