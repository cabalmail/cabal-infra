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
            model = FeedItemDetailViewModel(item: item, subscription: subscription,
                                            engine: appState.client?.rssSync, preferences: preferences)
        }
    }

    @ViewBuilder
    private func content(_ model: FeedItemDetailViewModel) -> some View {
        if model.showingArticle, let url = model.articleURL {
            ArticleWebView(url: url, dataStoreID: model.dataStoreID, readerMode: model.readerMode)
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
                    HTMLBodyView(
                        html: model.item.bodyHtml,
                        inlineImages: [:],
                        allowRemote: model.remoteContentAllowed,
                        readerMode: model.readerMode
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
            HStack(spacing: 8) {
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
        ToolbarItem {
            Button {
                model.toggleReaderMode()
            } label: {
                Label(model.readerMode ? "Show original formatting" : "Show reader view",
                      systemImage: model.readerMode ? "text.alignleft" : "doc.richtext")
            }
            .accessibilityIdentifier("feed.reader.readerMode")
        }
        articleToolbarItems(model)
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
                    Label(model.showingArticle ? "Show feed content" : "Open article",
                          systemImage: model.showingArticle ? "doc.plaintext" : "safari")
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
}
