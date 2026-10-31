import SwiftUI
import CabalmailKit

/// The feed reader's toolbar, drawn from `FeedReaderToolbarLayout`, which
/// says which actions each shape of the bar draws and in what order. This
/// picks the shape: the touch top bar on iOS, where three items plus a title
/// fit and the View menu carries the rest, and the wide bar on macOS and
/// visionOS, where each action is its own item. Every control carries its
/// `FeedReaderAction` identifier (`feed.reader.<action>`).
///
/// The bar takes the value that decides its set (`hasArticle`) from the
/// reader's view, which reads it from the model, so the set follows it.
/// `showingArticle` only changes what the items draw, never which slots the
/// wide bar holds (#2206). Each item is a `FeedReaderBarItem` view, which reads
/// the item's state itself: a toolbar content type's body did not refresh
/// for the model's reads (measured: Flag kept reading "Flag" after a flag).
struct FeedReaderToolbar: ToolbarContent {
    let model: FeedItemDetailViewModel
    let hasArticle: Bool
    /// The article control says when it needs a connection.
    let isOffline: Bool
    /// Whether the reader draws its own bar under its pane, in a tall
    /// window on iOS (`FeedReaderActionBar`), which then carries these
    /// actions: the navigation bar draws none, so no identifier is drawn
    /// twice.
    var drawsOwnBar = false

    var body: some ToolbarContent {
        #if os(iOS)
        // The View menu is ranked above the other items in the system's
        // overflow (iOS 27; an iPhone Duo's vertical strip folds far sooner
        // than a horizontal bar): it is the only touch route to reader view,
        // remote content and the article, as the mail reader's menu is the
        // only route to its demoted actions.
        // `FeedReaderToolbarLayoutTests` pins the list as Read, Flag, View.
        let actions = FeedReaderToolbarLayout.menuBar
        if !drawsOwnBar {
            ToolbarItem { item(actions[0]) }
            ToolbarItem { item(actions[1]) }
            ToolbarItem { item(actions[2]) }
                .keepsInBarFirst()
        }
        #else
        let actions = FeedReaderToolbarLayout.wideBar(hasArticle: hasArticle)
        ForEach(actions, id: \.self) { action in
            ToolbarItem { item(action) }
        }
        #endif
    }

    private func item(_ action: FeedReaderAction) -> FeedReaderBarItem {
        FeedReaderBarItem(action: action, model: model, isOffline: isOffline)
    }
}

/// One control of the feed reader's bar, a view of its own so the state it
/// draws (read, flagged, reader view, remote content, the article) is
/// tracked and its face refreshes when that changes.
struct FeedReaderBarItem: View {
    let action: FeedReaderAction
    let model: FeedItemDetailViewModel
    let isOffline: Bool
    /// Drawn in the reader's own bar in a tall window
    /// (`FeedReaderActionBar`), where its View menu opens up from the bar
    /// and carries Previous and Next. The navigation bar's copy never does,
    /// as the mail reader's menu doesn't there either.
    var inOwnBar = false

    var body: some View {
        barItem(action)
    }

    @ViewBuilder
    private func barItem(_ action: FeedReaderAction) -> some View {
        switch action {
        case .read:
            Button {
                Task { await model.setRead(!model.item.isRead) }
            } label: {
                ReaderToggleFace.read(isRead: model.item.isRead).label
            }
            .accessibilityIdentifier(action.identifier)
        case .favorite:
            // The mail reader's flag control, word for word and glyph for
            // glyph (`ReaderToggleFace`); the identifier keeps the wire name
            // for the probes.
            Button {
                Task { await model.setFavorite(!model.item.isFavorite) }
            } label: {
                ReaderToggleFace.flag(isFlagged: model.item.isFavorite).label
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
            // What is on screen, which a link out of the reader moves for
            // that page alone (#2060), rather than the feed's own setting.
            ReaderToggleFace.readerView(isOn: model.effectiveReaderMode).label
        }
        .accessibilityIdentifier(FeedReaderAction.readerMode.identifier)
    }

    private var remoteContentButton: some View {
        Button {
            model.toggleRemoteContent()
        } label: {
            ReaderToggleFace.remoteContent(isShown: model.remoteContentAllowed).label
        }
        .disabled(!FeedReaderToolbarLayout.remoteContentEnabled(
            showingArticle: model.showingArticle, hasFeedContent: !model.item.bodyHtml.isEmpty
        ))
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
            showingArticle: model.showingArticle, hasArticle: model.articleURL != nil,
            fillsTallWindow: inOwnBar
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
        .menuOrderFromBottomBar(inOwnBar)
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
        case .previousNext:
            ReaderListStepRow()
        case .readerMode:
            readerModeButton
        case .remoteContent:
            remoteContentButton
        case .article:
            articleButton
        case .openInBrowser, .shareLink, .copyLink:
            if let url = model.articleURL {
                linkRow(item, url: url, browserIcon: browserIcon)
            }
        }
    }

    /// The rows that act on the item's article link.
    @ViewBuilder
    private func linkRow(_ item: FeedReaderMenuItem, url: URL, browserIcon: Bool) -> some View {
        switch item {
        case .openInBrowser:
            if browserIcon {
                Link(destination: url) { Label("Open in browser", systemImage: "safari") }
            } else {
                Link("Open in browser", destination: url)
            }
        case .shareLink:
            ShareLink(item: url) { Label("Share link", systemImage: "square.and.arrow.up") }
        case .copyLink:
            Button("Copy link") { copyToPasteboard(url.absoluteString) }
        case .previousNext, .readerMode, .remoteContent, .article:
            EmptyView()
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
