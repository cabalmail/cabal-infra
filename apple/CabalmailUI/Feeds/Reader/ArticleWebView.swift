import SwiftUI
import CabalmailKit
@preconcurrency import WebKit

/// The publisher's page for a feed item, in a `WKWebView` whose storage is
/// the subscription's own (`WKWebsiteDataStore(forIdentifier:)`, D11): a
/// login on this feed's site never leaks to another feed's, even at the
/// same publisher. JavaScript stays on for the live page - publishers need
/// it - and off for the reader rendering, whose document also refuses
/// script, plugins and frames by its own content security policy (#1911).
///
/// Reader mode runs the vendored Readability.js over the loaded page and
/// re-renders the extracted article with the mail reader's stylesheet, at
/// the system text size (`ReaderTextScale`); the user can flip back to the
/// publisher's own rendering at any time.
struct ArticleWebView: View {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool
    let isOffline: Bool

    /// The last top-level load error, cleared when a load finishes.
    @State private var failure: String?
    /// Bumped by Retry to rebuild the web view and load again.
    @State private var attempt = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ArticleWebViewRepresentable(url: url, dataStoreID: dataStoreID, readerMode: readerMode,
                                    textScale: dynamicTypeSize.bodyTextScale,
                                    onFailure: { failure = $0 })
            .id(attempt)
            .overlay {
                if failure != nil { failureNotice }
            }
    }

    /// A plain notice in place of WebKit's error page: the offline case says
    /// so; anything else shows the error text. Retry reloads.
    private var failureNotice: some View {
        ContentUnavailableView {
            Label(isOffline ? "Needs a connection" : "Couldn't load the article",
                  systemImage: isOffline ? "wifi.slash" : "exclamationmark.triangle")
        } description: {
            Text(isOffline ? "The article will load when you're back online." : (failure ?? ""))
        } actions: {
            Button("Retry") {
                failure = nil
                attempt += 1
            }
            .accessibilityIdentifier("feed.article.retry")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

#if os(macOS)
private struct ArticleWebViewRepresentable: NSViewRepresentable {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool
    let textScale: Double
    let onFailure: @MainActor (String?) -> Void

    func makeCoordinator() -> ArticleWebCoordinator { ArticleWebCoordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(url: url, dataStoreID: dataStoreID)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.apply(readerMode: readerMode, textScale: textScale, on: nsView)
    }
}
#else
private struct ArticleWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool
    let textScale: Double
    let onFailure: @MainActor (String?) -> Void

    func makeCoordinator() -> ArticleWebCoordinator { ArticleWebCoordinator(onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(url: url, dataStoreID: dataStoreID)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.apply(readerMode: readerMode, textScale: textScale, on: uiView)
    }
}
#endif

/// Owns the page/reader state machine. `readerMode` is what the toolbar
/// asks for; `showingReader` is what is on screen. When they differ and the
/// live page has finished loading, extraction runs (or the page reloads).
/// A reader on screen at another text size than the system's renders again.
@MainActor
final class ArticleWebCoordinator: NSObject, WKNavigationDelegate {
    private var pageURL: URL?
    private var wantsReader = false
    private var showingReader = false
    private var pageLoaded = false
    private var extracting = false
    /// The live page's article, extracted once; the reader document is built
    /// from it at the text size of the moment.
    private var article: ExtractedArticle?
    /// The system text size, as `DynamicTypeSize.bodyTextScale`.
    private var textScale: Double = 1
    /// The text size the reader on screen was rendered at.
    private var readerTextScale: Double?
    /// Set from `showReader` until the reader document commits. That load,
    /// and no other, runs with page JavaScript off (#1911). `showingReader`
    /// can't stand in for it: it is still true while a link tapped in the
    /// reader is decided, and that link must load its page with scripts on.
    private var loadingReader = false
    /// A link tapped in the reader is loading. The reader state changes only
    /// once its page commits, so a link that opens nothing here (a new-window
    /// link, a download) leaves the reader as it was.
    private var linkOutOfReader = false
    /// Reports a top-level load failure (or nil once a load finishes) to the
    /// SwiftUI layer, which draws the notice.
    private let onFailure: @MainActor (String?) -> Void

    init(onFailure: @escaping @MainActor (String?) -> Void) {
        self.onFailure = onFailure
    }

    func makeWebView(url: URL, dataStoreID: UUID?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let dataStoreID {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        }
        // The live page is the publisher's site and needs its scripts. The
        // reader rendering's own load turns them off (`decidePolicyFor`).
        // swiftlint:disable:next content_javascript_enabled
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Does nothing on the live page: only the reader document carries
        // the scale it reads.
        ReaderTextScale.install(on: configuration.userContentController)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if os(iOS) || os(visionOS)
        webView.allowsBackForwardNavigationGestures = true
        #endif
        pageURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func apply(readerMode: Bool, textScale: Double, on webView: WKWebView) {
        wantsReader = readerMode
        self.textScale = textScale
        reconcile(on: webView)
    }

    private func reconcile(on webView: WKWebView) {
        guard pageLoaded, !extracting else { return }
        if wantsReader, showingReader {
            if readerTextScale != textScale, let article {
                showReader(article, on: webView)
            }
            return
        }
        guard wantsReader != showingReader else { return }
        if wantsReader {
            if let article {
                showReader(article, on: webView)
            } else {
                extract(on: webView)
            }
        } else if let pageURL {
            showingReader = false
            pageLoaded = false
            loadingReader = false
            linkOutOfReader = false
            webView.load(URLRequest(url: pageURL))
        }
    }

    private func extract(on webView: WKWebView) {
        guard let script = ReaderAssets.readabilityScript() else { return }
        extracting = true
        let program = script + "\n" + Self.extractionProgram
        webView.evaluateJavaScript(program) { [weak self] result, _ in
            guard let self else { return }
            Task { @MainActor in
                self.extracting = false
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let article = try? JSONDecoder().decode(ExtractedArticle.self, from: data)
                else {
                    // Extraction failed: stay on the live page; the toggle
                    // still reads "reader" so the user can try again.
                    return
                }
                self.article = article
                self.showReader(article, on: webView)
            }
        }
    }

    private func showReader(_ article: ExtractedArticle, on webView: WKWebView) {
        showingReader = true
        pageLoaded = false
        loadingReader = true
        linkOutOfReader = false
        readerTextScale = textScale
        let document = ArticleReaderDocument.html(
            for: article, sourceHost: pageURL?.host() ?? "", textScale: textScale)
        webView.loadHTMLString(document, baseURL: pageURL)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        loadingReader = false
        if linkOutOfReader {
            // The link's page is on screen but not loaded, so nothing
            // extracts it yet: `didFinish` adopts its URL, then `reconcile`
            // extracts it again while the toolbar asks for the reader.
            linkOutOfReader = false
            showingReader = false
            pageLoaded = false
            article = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        onFailure(nil)
        // A new top-level page (the user followed a link) invalidates the
        // extraction cached for the previous one.
        if !showingReader, webView.url != pageURL, let current = webView.url,
           current.scheme?.hasPrefix("http") == true {
            pageURL = current
            article = nil
        }
        reconcile(on: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingReader = false
        linkOutOfReader = false
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// A cancelled load (a new request superseding this one, WebKit's
    /// "frame load interrupted" on a download or a redirect) is not a failure.
    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        pageLoaded = false
        onFailure(nsError.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // The reader rendering holds the publisher's markup, event handlers
        // included, so its load runs no page script; the live page needs its
        // scripts. The load's request carries the page's https URL, not
        // about:blank, so the scheme can't tell the two apart.
        let inMainFrame = navigationAction.targetFrame?.isMainFrame == true
        // swiftlint:disable:next content_javascript_enabled
        preferences.allowsContentJavaScript = ArticleNavigationPolicy.allowsJavaScript(
            type: navigationAction.navigationType, inMainFrame: inMainFrame, loadingReader: loadingReader)
        if ArticleNavigationPolicy.leavesReader(
            type: navigationAction.navigationType, url: navigationAction.request.url,
            inMainFrame: inMainFrame, showingReader: showingReader) {
            linkOutOfReader = true
        }
        return (.allow, preferences)
    }

    /// Runs Readability over a clone of the document and returns JSON. The
    /// video pattern matches nothing, so Readability drops every iframe,
    /// embed and object, video players included: reader mode runs no
    /// third-party code, and the players stay on the publisher's page.
    static let extractionProgram = """
    (function () {
      try {
        var article = new Readability(document.cloneNode(true), { allowedVideoRegex: /(?!)/ }).parse();
        if (!article) { return null; }
        return JSON.stringify({ title: article.title || "", byline: article.byline || "",
                                content: article.content || "" });
      } catch (e) { return null; }
    })();
    """
}

struct ExtractedArticle: Decodable, Equatable {
    var title: String
    var byline: String
    var content: String
}

/// Wraps Readability's output in the mail reader's stylesheet (`rewrite`'s
/// reader mode), so an article reads like a reader-mode message.
enum ArticleReaderDocument {
    static func html(for article: ExtractedArticle, sourceHost: String, textScale: Double = 1) -> String {
        let title = escape(article.title)
        let byline = escape(article.byline)
        let meta = [byline, escape(sourceHost)].filter { !$0.isEmpty }.joined(separator: " · ")
        let body = """
        <article>
        <h1>\(title)</h1>
        \(meta.isEmpty ? "" : "<p class=\"cabal-byline\"><small>\(meta)</small></p>")
        \(article.content)
        </article>
        """
        return contentPolicy + rewrite(html: body, inlineImages: [:], readerMode: true, textScale: textScale)
    }

    /// Refuses script, plugins and frames in the reader document, whatever
    /// the article carries (Readability keeps inline event handlers). It
    /// leads the document, because only a policy in the head applies and
    /// `rewrite` places its head defaults after the first tag that starts
    /// with `<head`, which an article's `<header>` also matches.
    static let contentPolicy = "<meta http-equiv=\"Content-Security-Policy\" "
        + "content=\"script-src 'none'; object-src 'none'; frame-src 'none'\">"

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
