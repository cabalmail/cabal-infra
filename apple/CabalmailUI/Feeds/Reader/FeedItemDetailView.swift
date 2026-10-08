import SwiftUI
import CabalmailKit

/// Reader for one feed item: the in-feed body through the same sandboxed
/// `HTMLBodyView` the mail reader uses, or the publisher's page in
/// `ArticleWebView` on the subscription's own web-view storage. Which one
/// opens first, and whether reader styling is on, come from the
/// subscription's stored preferences.
struct FeedItemDetailView: View {
    let item: RssItem
    let subscription: RssSubscription?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var model: FeedItemDetailViewModel?
    @State private var isOffline = false
    /// Where the reader was in this item's body last time it was open, from
    /// the local position cache — reapplied once the body loads. Snapshotted
    /// into state (rather than read from the coordinator in `body`) so the
    /// capture stream below doesn't re-render the web view on every report.
    @State private var restoreAnchor: String?

    var body: some View {
        Group {
            if let model {
                content(model)
                    .toolbar {
                        FeedReaderToolbar(model: model, showingArticle: model.showingArticle,
                                          hasArticle: model.articleURL != nil, isOffline: isOffline)
                    }
            } else {
                ProgressView()
            }
        }
        .navigationTitle((model?.subscription ?? subscription)?.displayTitle ?? "Feed")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // Build the model from `.onAppear`, not `.task`: on an iPhone-compact
        // NavigationStack push, `.task` can fire twice for the same identity
        // and cancel both at entry (see `MessageDetailView`'s note). The
        // launch restore pushes the list *and* the reader in one go, which
        // is exactly the case that left this view on its spinner until the
        // user backed out and reopened the item. The resolution below awaits
        // a store read, so it runs on an unstructured Task the modifier
        // can't cancel; `onAppear` re-firing is harmless (idempotent guard).
        .onAppear {
            guard model == nil else { return }
            restoreAnchor = appState.navCoordinator?.readingPosition(key: positionKey)?.anchor
            let client = appState.client
            let preferences = preferences
            let item = item
            let parentSubscription = subscription
            Task { @MainActor in
                // Resolve the subscription here rather than trusting the
                // parent's copy. The parent looks it up asynchronously
                // *after* the selection changes, so on a first open — or any
                // open after the reader was popped — it is still nil at this
                // point, and a model built from it would silently fall back
                // to the default open mode, styling, and remote-content
                // policy instead of the feed's own. Local, fast.
                let resolved: RssSubscription?
                if let parentSubscription {
                    resolved = parentSubscription
                } else if let store = client?.rssStore {
                    resolved = (try? await store.subscription(id: item.subscriptionId)) ?? nil
                } else {
                    resolved = nil
                }
                guard model == nil else { return }
                model = FeedItemDetailViewModel(item: item, subscription: resolved,
                                                engine: client?.rssSync, preferences: preferences)
            }
        }
        .task { await observeReachability() }
        // The toolbar's read and flag state follow the store once the model
        // exists (built from `onAppear`, above).
        .task(id: model.map(ObjectIdentifier.init)) { await model?.observe() }
    }

    /// True when the body runs under the bottom chrome's glass. On iOS that
    /// follows where `ReaderToolbarPolicy` puts the feed reader's actions:
    /// the system top bar at every width, so the bottom edge is the section
    /// tab bar's and the body runs under it, as the mail reader's does on its
    /// compact top bar. The other platforms keep it under their bottom chrome
    /// as before.
    private var bodyRunsUnderBottomBar: Bool {
        #if os(iOS)
        let isOS27OrLater: Bool
        if #available(iOS 27.0, *) { isOS27OrLater = true } else { isOS27OrLater = false }
        return ReaderToolbarPolicy.placement(
            for: .feeds, isRegularWidth: horizontalSizeClass == .regular, isOS27OrLater: isOS27OrLater
        ) == .topBar
        #else
        return true
        #endif
    }

    /// The item's key in the reading-position cache.
    private var positionKey: String { ReadingPositionKey.feed(itemID: item.id) }

    /// Mirrors reachability into the toolbar (the article button says when
    /// it needs a connection) and the article view (its offline notice).
    private func observeReachability() async {
        #if canImport(Network)
        guard let reachability = appState.client?.reachability else { return }
        isOffline = !reachability.isReachable
        for await reachable in reachability.changes() {
            isOffline = !reachable
        }
        #endif
    }

    @ViewBuilder
    private func content(_ model: FeedItemDetailViewModel) -> some View {
        if model.showingArticle, let url = model.articleURL {
            ArticleWebView(url: url, dataStoreID: model.dataStoreID, readerMode: model.readerMode,
                           isOffline: isOffline)
                .id(url)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header(model)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
                if model.item.bodyHtml.isEmpty {
                    ContentUnavailableView(
                        "No content in the feed", systemImage: "doc.text",
                        description: Text("This feed only lists the item. Open the article to read it.")
                    )
                } else {
                    // Same reader as mail, same scroll anchor plumbing: the
                    // position is restored from and streamed back to the
                    // local cache so a half-read item reopens where it was.
                    HTMLBodyView(
                        html: model.item.bodyHtml,
                        inlineImages: [:],
                        allowRemote: model.remoteContentAllowed,
                        readerMode: model.readerMode,
                        restoreAnchor: restoreAnchor,
                        // Under the tab bar's glass rather than above a black
                        // strip. The live article page (`ArticleWebView`)
                        // deliberately stays above the bar: WebKit pins a
                        // page's `position: fixed` bottom elements (consent
                        // and subscribe bars) to the web view's real bottom
                        // edge, where the tray shield would swallow their taps.
                        runsUnderBottomBar: bodyRunsUnderBottomBar,
                        onScrollCaptured: { capture in
                            appState.navCoordinator?.recordFeedScroll(itemID: item.id, capture: capture)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ model: FeedItemDetailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.item.title.isEmpty ? "Untitled" : model.item.title)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let url = model.articleURL {
                // The published article, in the browser, one tap from the
                // headline on every platform; the toolbar's in-app article
                // view is a separate thing and can be off screen on iPhone.
                Link(destination: url) {
                    Label("Open on \(url.host() ?? "the web")", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .accessibilityIdentifier("feed.reader.openInBrowser")
            }
            HStack(spacing: 8) {
                if let feed = subscription?.displayTitle, !feed.isEmpty {
                    Text(feed)
                        .lineLimit(1)
                }
                if !model.item.author.isEmpty {
                    Text(model.item.author)
                }
                Text(FeedItemDate.absolute(model.item.publishedAt))
                if let url = model.articleURL, let host = url.host() {
                    Text(host)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
