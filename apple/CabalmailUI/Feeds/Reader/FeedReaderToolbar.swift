import SwiftUI
import CabalmailKit

/// The feed reader's toolbar, drawn from `FeedReaderToolbarLayout`, which
/// says which actions each shape of the bar draws and in what order. This
/// picks the shape: the touch top bar on iOS, where three items plus a title
/// fit and the View menu carries the rest, and the wide bar on macOS and
/// visionOS, where each action is its own item. Every control carries its
/// `FeedReaderAction` identifier (`feed.reader.<action>`).
struct FeedReaderToolbar: ToolbarContent {
    let model: FeedItemDetailViewModel
    /// The article control says when it needs a connection.
    let isOffline: Bool

    var body: some ToolbarContent {
        #if os(iOS)
        ForEach(FeedReaderToolbarLayout.menuBar, id: \.self) { action in
            ToolbarItem { barItem(action) }
        }
        #else
        let actions = FeedReaderToolbarLayout.wideBar(
            showingArticle: model.showingArticle, hasArticle: model.articleURL != nil
        )
        ForEach(actions, id: \.self) { action in
            ToolbarItem { barItem(action) }
        }
        #endif
    }

    @ViewBuilder
    private func barItem(_ action: FeedReaderAction) -> some View {
        switch action {
        case .read:
            Button {
                Task { await model.setRead(!model.item.isRead) }
            } label: {
                Label(model.item.isRead ? "Mark as unread" : "Mark as read",
                      systemImage: model.item.isRead ? "envelope.badge" : "envelope.open")
            }
            .accessibilityIdentifier(action.identifier)
        case .favorite:
            // The mail reader's flag control, word for word and glyph for
            // glyph (`MessageDetailView+FlagOptions`); the identifier keeps
            // the wire name for the probes.
            Button {
                Task { await model.setFavorite(!model.item.isFavorite) }
            } label: {
                Label(model.item.isFavorite ? "Unflag" : "Flag",
                      systemImage: model.item.isFavorite ? "flag.slash" : "flag")
            }
            .accessibilityIdentifier(action.identifier)
        case .readerMode:
            readerModeButton
        case .remoteContent:
            remoteContentButton
        case .article:
            articleButton
        case .more:
            moreMenu
        }
    }

    private var readerModeButton: some View {
        Button {
            model.toggleReaderMode()
        } label: {
            Label(model.readerMode ? "Show original formatting" : "Show reader view",
                  systemImage: model.readerMode ? "text.alignleft" : "doc.richtext")
        }
        .accessibilityIdentifier(FeedReaderAction.readerMode.identifier)
    }

    private var remoteContentButton: some View {
        Button {
            model.toggleRemoteContent()
        } label: {
            Label(model.remoteContentAllowed ? "Hide remote content" : "Show remote content",
                  systemImage: model.remoteContentAllowed ? "eye.fill" : "eye.slash")
        }
        .disabled(model.item.bodyHtml.isEmpty)
        .accessibilityIdentifier(FeedReaderAction.remoteContent.identifier)
    }

    private var articleButton: some View {
        Button {
            model.toggleArticle()
        } label: {
            Label(articleTitle, systemImage: articleSymbol)
        }
        .accessibilityIdentifier(FeedReaderAction.article.identifier)
    }

    #if os(iOS)
    /// iOS: the View menu, the only touch route to reader view, remote
    /// content and the article (`FeedReaderToolbarLayout.viewMenu`).
    private var moreMenu: some View {
        let sections = FeedReaderToolbarLayout.viewMenu(
            showingArticle: model.showingArticle, hasArticle: model.articleURL != nil
        )
        return Menu {
            ForEach(sections.indices, id: \.self) { index in
                if index > 0 { Divider() }
                ForEach(sections[index], id: \.self) { item in
                    menuRow(item, browserIcon: true)
                }
            }
        } label: {
            Label("View", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier(FeedReaderAction.more.identifier)
    }
    #else
    /// macOS and visionOS: the link rows (`FeedReaderToolbarLayout.moreMenu`)
    /// for an item with an article; the wide bar draws the rest as items.
    @ViewBuilder
    private var moreMenu: some View {
        if model.articleURL != nil {
            Menu {
                ForEach(FeedReaderToolbarLayout.moreMenu, id: \.self) { item in
                    menuRow(item, browserIcon: false)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier(FeedReaderAction.more.identifier)
        }
    }
    #endif

    /// One menu row. The link rows need the item's article URL, which the
    /// layout only lists them for.
    @ViewBuilder
    private func menuRow(_ item: FeedReaderMenuItem, browserIcon: Bool) -> some View {
        switch item {
        case .readerMode:
            readerModeButton
        case .remoteContent:
            remoteContentButton
        case .article:
            articleButton
        case .openInBrowser:
            if let url = model.articleURL {
                if browserIcon {
                    Link(destination: url) { Label("Open in browser", systemImage: "safari") }
                } else {
                    Link("Open in browser", destination: url)
                }
            }
        case .shareLink:
            if let url = model.articleURL {
                ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
            }
        case .copyLink:
            if let url = model.articleURL {
                Button("Copy link") { copyToPasteboard(url.absoluteString) }
            }
        }
    }

    /// "Open article" gains a "needs a connection" note while unreachable;
    /// the button stays enabled because the page may already be cached.
    private var articleTitle: String {
        if model.showingArticle { return "Show feed content" }
        return isOffline ? "Open article (needs a connection)" : "Open article"
    }

    private var articleSymbol: String {
        if model.showingArticle { return "doc.plaintext" }
        return isOffline ? "wifi.slash" : "safari"
    }
}
