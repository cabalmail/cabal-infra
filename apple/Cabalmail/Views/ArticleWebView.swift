import SwiftUI
import CabalmailKit
@preconcurrency import WebKit

/// The publisher's page for a feed item, in a `WKWebView` whose storage is
/// the subscription's own (`WKWebsiteDataStore(forIdentifier:)`, D11): a
/// login on this feed's site never leaks to another feed's, even at the
/// same publisher. JavaScript stays on for the live page - publishers need
/// it - and off for the reader rendering.
///
/// Reader mode runs the vendored Readability.js over the loaded page and
/// re-renders the extracted article with the mail reader's stylesheet; the
/// user can flip back to the publisher's own rendering at any time.
struct ArticleWebView: View {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool

    var body: some View {
        ArticleWebViewRepresentable(url: url, dataStoreID: dataStoreID, readerMode: readerMode)
    }
}

#if os(macOS)
private struct ArticleWebViewRepresentable: NSViewRepresentable {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool

    func makeCoordinator() -> ArticleWebCoordinator { ArticleWebCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(url: url, dataStoreID: dataStoreID)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.apply(readerMode: readerMode, on: nsView)
    }
}
#else
private struct ArticleWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let dataStoreID: UUID?
    let readerMode: Bool

    func makeCoordinator() -> ArticleWebCoordinator { ArticleWebCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(url: url, dataStoreID: dataStoreID)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.apply(readerMode: readerMode, on: uiView)
    }
}
#endif

/// Owns the page/reader state machine. `readerMode` is what the toolbar
/// asks for; `showingReader` is what is on screen. When they differ and the
/// live page has finished loading, extraction runs (or the page reloads).
@MainActor
final class ArticleWebCoordinator: NSObject, WKNavigationDelegate {
    private var pageURL: URL?
    private var wantsReader = false
    private var showingReader = false
    private var pageLoaded = false
    private var extracting = false
    private var readerDocument: String?

    func makeWebView(url: URL, dataStoreID: UUID?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let dataStoreID {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: dataStoreID)
        }
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if os(iOS)
        webView.allowsBackForwardNavigationGestures = true
        #endif
        pageURL = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func apply(readerMode: Bool, on webView: WKWebView) {
        wantsReader = readerMode
        reconcile(on: webView)
    }

    private func reconcile(on webView: WKWebView) {
        guard wantsReader != showingReader, pageLoaded, !extracting else { return }
        if wantsReader {
            if let readerDocument {
                showReader(readerDocument, on: webView)
            } else {
                extract(on: webView)
            }
        } else if let pageURL {
            showingReader = false
            pageLoaded = false
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
                let document = ArticleReaderDocument.html(for: article, sourceHost: self.pageURL?.host() ?? "")
                self.readerDocument = document
                self.showReader(document, on: webView)
            }
        }
    }

    private func showReader(_ document: String, on webView: WKWebView) {
        showingReader = true
        pageLoaded = false
        webView.loadHTMLString(document, baseURL: pageURL)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        // A new top-level page (the user followed a link) invalidates the
        // extraction cached for the previous one.
        if !showingReader, webView.url != pageURL, let current = webView.url,
           current.scheme?.hasPrefix("http") == true {
            pageURL = current
            readerDocument = nil
        }
        reconcile(on: webView)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        // The reader rendering is static HTML we built; the live page needs
        // its scripts.
        preferences.allowsContentJavaScript = !(showingReader && navigationAction.request.url?.scheme == "about")
        if showingReader, navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, url.scheme?.hasPrefix("http") == true {
            // A link tapped inside the reader rendering leaves reader mode for
            // the live destination, like Safari Reader does.
            showingReader = false
            readerDocument = nil
            pageURL = url
        }
        return (.allow, preferences)
    }

    /// Runs Readability over a clone of the document and returns JSON.
    static let extractionProgram = """
    (function () {
      try {
        var article = new Readability(document.cloneNode(true)).parse();
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
    static func html(for article: ExtractedArticle, sourceHost: String) -> String {
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
        return rewrite(html: body, inlineImages: [:], readerMode: true)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
