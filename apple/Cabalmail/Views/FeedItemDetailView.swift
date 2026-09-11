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
                    .toolbar { toolbarItems(model) }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(subscription?.displayTitle ?? "Feed")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: item.id) {
            restoreAnchor = appState.navCoordinator?.readingPosition(key: positionKey)?.anchor
            model = FeedItemDetailViewModel(item: item, subscription: subscription,
                                            engine: appState.client?.rssSync, preferences: preferences)
        }
        .task { await observeReachability() }
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
                        onScrollCaptured: { capture in
                            appState.navCoordinator?.savePosition(
                                key: positionKey, anchor: capture.anchor, offset: nil, atTop: capture.isAtTop
                            )
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

    @ToolbarContentBuilder
    private func toolbarItems(_ model: FeedItemDetailViewModel) -> some ToolbarContent {
        ToolbarItem {
            Button {
                Task { await model.setRead(!model.item.isRead) }
            } label: {
                Label(model.item.isRead ? "Mark as unread" : "Mark as read",
                      systemImage: model.item.isRead ? "envelope.badge" : "envelope.open")
            }
            .accessibilityIdentifier("feed.reader.read")
        }
        ToolbarItem {
            Button {
                Task { await model.setFavorite(!model.item.isFavorite) }
            } label: {
                Label(model.item.isFavorite ? "Remove favorite" : "Favorite",
                      systemImage: model.item.isFavorite ? "star.fill" : "star")
            }
            .accessibilityIdentifier("feed.reader.favorite")
        }
        #if os(iOS)
        // An iPhone navigation bar shows about three trailing items and
        // silently drops the rest, which is where "Open article" went. The
        // view controls share one menu there; macOS and visionOS have room.
        ToolbarItem {
            Menu {
                readerModeButton(model)
                articleMenuItems(model)
            } label: {
                Label("View", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("feed.reader.more")
        }
        #else
        ToolbarItem { readerModeButton(model) }
        articleToolbarItems(model)
        #endif
    }

    private func readerModeButton(_ model: FeedItemDetailViewModel) -> some View {
        Button {
            model.toggleReaderMode()
        } label: {
            Label(model.readerMode ? "Show original formatting" : "Show reader view",
                  systemImage: model.readerMode ? "text.alignleft" : "doc.richtext")
        }
        .accessibilityIdentifier("feed.reader.readerMode")
    }

    /// The article controls as menu rows (iOS), same actions as the toolbar
    /// items on the wide platforms.
    @ViewBuilder
    private func articleMenuItems(_ model: FeedItemDetailViewModel) -> some View {
        if !model.showingArticle {
            Button {
                model.toggleRemoteContent()
            } label: {
                Label(model.remoteContentAllowed ? "Hide remote content" : "Show remote content",
                      systemImage: model.remoteContentAllowed ? "eye.fill" : "eye.slash")
            }
            .disabled(model.item.bodyHtml.isEmpty)
        }
        if let url = model.articleURL {
            Divider()
            Button {
                model.toggleArticle()
            } label: {
                Label(articleTitle(model), systemImage: articleSymbol(model))
            }
            Link(destination: url) { Label("Open in browser", systemImage: "safari") }
            ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
            Button("Copy link") { copyToPasteboard(url.absoluteString) }
        }
    }

    @ToolbarContentBuilder
    private func articleToolbarItems(_ model: FeedItemDetailViewModel) -> some ToolbarContent {
        if !model.showingArticle {
            ToolbarItem {
                Button {
                    model.toggleRemoteContent()
                } label: {
                    Label(model.remoteContentAllowed ? "Hide remote content" : "Show remote content",
                          systemImage: model.remoteContentAllowed ? "eye.fill" : "eye.slash")
                }
                .disabled(model.item.bodyHtml.isEmpty)
                .accessibilityIdentifier("feed.reader.remoteContent")
            }
        }
        if model.articleURL != nil {
            ToolbarItem {
                Button {
                    model.toggleArticle()
                } label: {
                    Label(articleTitle(model), systemImage: articleSymbol(model))
                }
                .accessibilityIdentifier("feed.reader.article")
            }
        }
        if let url = model.articleURL {
            ToolbarItem {
                Menu {
                    Link("Open in browser", destination: url)
                    ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
                    Button("Copy link") { copyToPasteboard(url.absoluteString) }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .accessibilityIdentifier("feed.reader.more")
            }
        }
    }

    /// "Open article" gains a "needs a connection" note while unreachable;
    /// the button stays enabled because the page may already be cached.
    private func articleTitle(_ model: FeedItemDetailViewModel) -> String {
        if model.showingArticle { return "Show feed content" }
        return isOffline ? "Open article (needs a connection)" : "Open article"
    }

    private func articleSymbol(_ model: FeedItemDetailViewModel) -> String {
        if model.showingArticle { return "doc.plaintext" }
        return isOffline ? "wifi.slash" : "safari"
    }

}
