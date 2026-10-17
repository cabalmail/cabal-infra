import CabalmailKit
import WebKit
import XCTest
@testable import CabalmailUI

/// Feed reader mode runs no script from the article (#1911), by two locks
/// that each hold on their own: the coordinator loads the reader document
/// with page JavaScript off, and the document carries a policy that
/// refuses script, plugins and frames.
@MainActor
final class ArticleNavigationPolicyTests: XCTestCase {
    func testOnlyTheReaderLoadRunsWithoutScript() {
        XCTAssertFalse(ArticleNavigationPolicy.allowsJavaScript(type: .other, inMainFrame: true, loadingReader: true))
    }

    func testEveryOtherNavigationKeepsScript() {
        let cases = [
            Navigation(.other, inMainFrame: true, loadingReader: false, "the live page, and the toggle back to it"),
            Navigation(.linkActivated, inMainFrame: true, loadingReader: true, "a link tapped as the reader loads"),
            Navigation(.linkActivated, inMainFrame: true, loadingReader: false, "a link out of the reader"),
            Navigation(.backForward, inMainFrame: true, loadingReader: false, "back or forward"),
            Navigation(.reload, inMainFrame: true, loadingReader: false, "reload"),
            Navigation(.other, inMainFrame: false, loadingReader: true, "a subframe"),
        ]
        for navigation in cases {
            let allows = ArticleNavigationPolicy.allowsJavaScript(
                type: navigation.type, inMainFrame: navigation.inMainFrame, loadingReader: navigation.loadingReader)
            XCTAssertTrue(allows, navigation.label)
        }
    }

    func testALinkTappedInTheReaderLeavesIt() {
        for url in ["https://example.com/next", "http://example.com/next"] {
            XCTAssertTrue(ArticleNavigationPolicy.leavesReader(
                type: .linkActivated, url: URL(string: url), inMainFrame: true, showingReader: true), url)
        }
    }

    func testOnlyALinkOpeningHereLeavesTheReader() {
        let next = URL(string: "https://example.com/next")
        XCTAssertFalse(ArticleNavigationPolicy.leavesReader(
            type: .linkActivated, url: next, inMainFrame: false, showingReader: true), "a new-window link")
        XCTAssertFalse(ArticleNavigationPolicy.leavesReader(
            type: .linkActivated, url: URL(string: "mailto:someone@example.com"), inMainFrame: true,
            showingReader: true), "a mail link")
        XCTAssertFalse(ArticleNavigationPolicy.leavesReader(
            type: .linkActivated, url: next, inMainFrame: true, showingReader: false), "a link on the live page")
        for type in [WKNavigationType.backForward, .reload, .other, .formSubmitted] {
            XCTAssertFalse(ArticleNavigationPolicy.leavesReader(
                type: type, url: next, inMainFrame: true, showingReader: true), "\(type.rawValue)")
        }
    }

    private struct Navigation {
        let type: WKNavigationType
        let inMainFrame: Bool
        let loadingReader: Bool
        let label: String

        init(_ type: WKNavigationType, inMainFrame: Bool, loadingReader: Bool, _ label: String) {
            self.type = type
            self.inMainFrame = inMainFrame
            self.loadingReader = loadingReader
            self.label = label
        }
    }

    func testTheReaderDocumentLeadsWithItsPolicy() {
        let article = ExtractedArticle(title: "T", byline: "", content: "<header><p>Kicker</p></header><p>Body</p>")
        let html = ArticleReaderDocument.html(for: article, sourceHost: "example.com")
        XCTAssertTrue(html.hasPrefix(ArticleReaderDocument.contentPolicy))
        for directive in ["script-src 'none'", "object-src 'none'", "frame-src 'none'"] {
            XCTAssertTrue(ArticleReaderDocument.contentPolicy.contains(directive), directive)
        }
    }
}

/// The reader document in a real `WKWebView` with page JavaScript on, as
/// #1911's harness loaded it: an https base URL, so the policy alone has to
/// stop the article's script.
@MainActor
final class ArticleReaderDocumentScriptTests: XCTestCase {
    private static let base = URL(string: "https://feed.invalid/2026/article")!
    /// Each payload appends to `window.__cabalProbe` if it runs. The image is
    /// a broken `data:` URL, so its error fires without a network request.
    private static let payload = """
    <p>Body</p>
    <script>window.__cabalProbe = (window.__cabalProbe || '') + 'script;'</script>
    <img src="data:image/png;base64,AAAA" onerror="window.__cabalProbe = (window.__cabalProbe || '') + 'onerror;'">
    """

    private var window: NSWindow!
    private var loads: LoadWatcher!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        loads = LoadWatcher()
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        loads = nil
        super.tearDown()
    }

    func testTheReaderDocumentRunsNothingFromTheArticle() async throws {
        let html = ArticleReaderDocument.html(
            for: ExtractedArticle(title: "T", byline: "", content: Self.payload), sourceHost: "feed.invalid")
        let probe = try await probe(after: html)
        XCTAssertEqual(probe, "")
    }

    func testAHeaderInTheArticleDoesNotMoveThePolicy() async throws {
        let content = "<header><p>Kicker</p></header>" + Self.payload
        let html = ArticleReaderDocument.html(
            for: ExtractedArticle(title: "T", byline: "", content: content), sourceHost: "feed.invalid")
        let probe = try await probe(after: html)
        XCTAssertEqual(probe, "")
    }

    /// The control: the same markup without the policy runs both payloads,
    /// so an empty probe above means the policy stopped them.
    func testTheProbeSeesScriptThatRuns() async throws {
        let probe = try await probe(after: rewrite(html: Self.payload, inlineImages: [:], readerMode: true))
        XCTAssertTrue(probe.contains("script;"), probe)
        XCTAssertTrue(probe.contains("onerror;"), probe)
    }

    /// The players' addresses sit in attributes that load nothing, so the
    /// test needs no network; Readability keeps a player that names YouTube
    /// or Vimeo in any attribute unless the extraction says otherwise.
    func testExtractionDropsVideoPlayers() async throws {
        let script = try XCTUnwrap(ReaderAssets.readabilityScript(), "Readability.js was not synced")
        let sentence = "A sentence that reads like an article's body text. "
        let paragraph = "<p>" + String(repeating: sentence, count: 20) + "</p>"
        let page = """
        <html><head><title>T</title></head><body><article><h1>T</h1>\(paragraph)
        <iframe data-src="https://www.youtube.com/embed/abc"></iframe>
        <object data-src="https://player.vimeo.com/video/1"></object>
        \(paragraph)</article></body></html>
        """
        let webView = try await loaded(page)
        let json: String? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script + "\n" + ArticleWebCoordinator.extractionProgram) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
        let data = try XCTUnwrap(json?.data(using: .utf8), "extraction returned nothing")
        let article = try JSONDecoder().decode(ExtractedArticle.self, from: data)
        XCTAssertTrue(article.content.contains("A sentence"))
        XCTAssertFalse(article.content.contains("<iframe"))
        XCTAssertFalse(article.content.contains("<object"))
    }

    private func loaded(_ html: String) async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        webView.navigationDelegate = loads
        window.contentView = webView
        webView.loadHTMLString(html, baseURL: Self.base)
        for _ in 0..<400 where !loads.finished {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(loads.finished, "page never finished loading")
        return webView
    }

    /// Loads the document, waits for its images to settle, and reads what ran.
    private func probe(after html: String) async throws -> String {
        let webView = try await loaded(html)
        for _ in 0..<200 {
            let settled = try await webView.evaluateJavaScript(
                "Array.from(document.images).every(function (i) { return i.complete; })") as? Bool
            if settled == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        return try await webView.evaluateJavaScript("String(window.__cabalProbe || '')") as? String ?? "<no result>"
    }
}

@MainActor
private final class LoadWatcher: NSObject, WKNavigationDelegate {
    var finished = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }
}
