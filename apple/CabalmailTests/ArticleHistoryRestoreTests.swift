#if os(macOS)
import XCTest
import WebKit
import CabalmailKit
@testable import CabalmailUI

/// Back and forward in the feed article view put a page on screen in the
/// styling it was left in, and the reader toggle and the coordinator follow
/// it. Before, back from a page reached out of the reader showed the reader
/// rendering (WebKit restores it from its back-forward cache) under a toggle
/// reading "original", with the coordinator still holding the other page's
/// URL: the next toggle changed nothing on screen, or loaded the other page
/// in place of the article.
///
/// The pages come from a URL scheme handler, so the web view keeps real
/// history without a network, and the coordinator is told that its scheme,
/// "httpx", is a publisher's as http and https are: a link tapped in the
/// reader then takes #2060's link-out path, as it does in the app. The
/// view model and the
/// coordinator are wired as `FeedItemDetailView` wires them: every change to
/// the model is handed down through `apply`, as a render would.
@MainActor
final class ArticleHistoryRestoreTests: XCTestCase {
    private final class Pages: NSObject, WKURLSchemeHandler {
        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return }
            let sentence = "A sentence that reads like an article's body text. "
            let paragraph = "<p>" + String(repeating: sentence, count: 20) + "</p>"
            let name = url.lastPathComponent
            let page = "<html><head><title>\(name)</title></head><body><article><h1>\(name)</h1>"
                + "\(paragraph)<p><a href=\"httpx://site.test/other\">other</a></p>\(paragraph)"
                + "</article></body></html>"
            let data = Data(page.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
                                        textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
    }

    private let article = URL(string: "httpx://site.test/article")!
    private let other = URL(string: "httpx://site.test/other")!
    private var window: NSWindow!
    private var model: FeedItemDetailViewModel!
    private var coordinator: ArticleWebCoordinator!
    private var view: WKWebView!
    /// How many pages the coordinator has reported restored (`goBack`).
    private var restoredPages = 0

    override func setUp() async throws {
        try await super.setUp()
        let item = RssItem(feedId: "f", subscriptionId: "s", itemId: "i", sortKey: "k", title: "t",
                           url: article.absoluteString, publishedAt: "2026-11-04T00:00:00Z")
        model = FeedItemDetailViewModel(item: item, subscription: nil, engine: nil,
                                        preferences: Preferences(store: InMemoryPreferenceStore()))
        coordinator = ArticleWebCoordinator(
            onFailure: { _ in },
            onLeftReader: { [unowned self] in model.leftReaderThroughLink(); render() },
            onRestoredPage: { [unowned self] in
                model.restoredPage(showingReader: $0)
                restoredPages += 1
                render()
            })
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(Pages(), forURLScheme: "httpx")
        coordinator.webSchemes.insert("httpx")
        view = coordinator.makeWebView(url: article, dataStoreID: nil, configuration: configuration)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        render()
    }

    override func tearDown() async throws {
        window.contentView = nil
        window = nil
        try await super.tearDown()
    }

    /// What `FeedItemDetailView` does on every render.
    private func render() {
        coordinator.apply(readerMode: model.effectiveReaderMode, textScale: 1, on: view)
    }

    private func toggle() {
        model.toggleReaderMode()
        render()
    }

    // MARK: - The two ways back

    /// The feed opens articles in the reader. Following a link out of it and
    /// coming back puts the reader rendering back, and the toggle says so;
    /// each toggle after that changes what is on screen, on the article.
    func testBackToTheReaderShowsTheReaderAndTheToggleFollows() async throws {
        XCTAssertTrue(model.effectiveReaderMode, "precondition: the feed opens articles in the reader")
        try await expect(.reader, on: "article")

        try await followTheLink()
        try await expect(.original, on: "other")
        XCTAssertFalse(model.effectiveReaderMode, "precondition: the link out of the reader opened the page as served")
        try await goBack()
        try await expect(.reader, on: "article")
        XCTAssertTrue(model.effectiveReaderMode, "the toggle reads original over the reader rendering")

        toggle()
        try await expect(.original, on: "article")
        XCTAssertEqual(view.url, article, "the toggle loaded another page in place of the article")
        toggle()
        try await expect(.reader, on: "article")
    }

    /// The same from the publisher's layout: coming back shows it, the
    /// toggle says so, and asking for the reader renders this article, not
    /// the page the link led to.
    func testBackToTheOriginalShowsTheOriginalAndTheToggleFollows() async throws {
        try await expect(.reader, on: "article")
        toggle()
        try await expect(.original, on: "article")

        try await followTheLink()
        try await expect(.original, on: "other")
        try await goBack()
        try await expect(.original, on: "article")
        XCTAssertFalse(model.effectiveReaderMode, "the toggle reads reader over the publisher's layout")

        toggle()
        try await expect(.reader, on: "article")
        XCTAssertEqual(view.url, article, "the reader rendered under the other page's address")
        toggle()
        try await expect(.original, on: "article")
        XCTAssertEqual(view.url, article, "the toggle loaded another page in place of the article")
    }

    // MARK: - Reading the page

    /// Taps the article's link to the other page: a link activation, as a
    /// finger's tap is.
    private func followTheLink() async throws {
        _ = try await view.evaluateJavaScript(
            "document.querySelector('a[href$=\"/other\"]').click(); true", contentWorld: .defaultClient)
    }

    /// Goes back and waits for the coordinator to report the page that came
    /// back. WebKit puts that page on screen at the navigation's commit, and
    /// only then does the coordinator ask it what it is (`adoptRestoredPage`,
    /// a script round trip); the answer sets the toggle. So the page reads
    /// as restored before the coordinator and the model have caught up, and
    /// a toggle in that gap is overwritten when the answer lands: the page
    /// never changes, and the step that waits for it times out (#2430).
    private func goBack(file: StaticString = #filePath, line: UInt = #line) async throws {
        let reported = restoredPages
        view.goBack()
        try await settle("went back, and the coordinator never reported the page that came back",
                         file: file, line: line) { restoredPages > reported }
    }

    private enum Styling { case reader, original }

    /// Waits for the page named `heading` in `styling`: the reader's
    /// stylesheet sets the body at 17px, the publisher's page is WebKit's
    /// 16px default.
    private func expect(_ styling: Styling, on heading: String,
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        let want = "\(heading)/\(styling == .reader ? 17 : 16)"
        var seen = ""
        try await settle("waited for \(want), the page reads \(seen)", file: file, line: line) {
            seen = await face()
            return seen == want && !view.isLoading
        }
    }

    /// Thrown by a step whose wait ran out, after it has recorded the
    /// failure: the steps after it would run against a page one step behind
    /// and fail for that reason alone.
    private struct StepTimedOut: Error {}

    /// Polls `condition` until it holds, and fails with `failure` and stops
    /// the test if it has not by `defaultWaitTimeout`. That ceiling bounds a
    /// failure, as `waitUntil`'s does: a condition that holds ends the wait
    /// on the next poll.
    private func settle(_ failure: @autoclosure () -> String, file: StaticString, line: UInt,
                        until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(defaultWaitTimeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail(failure(), file: file, line: line)
                throw StepTimedOut()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func face() async -> String {
        let script = "(document.querySelector('h1') ? document.querySelector('h1').textContent : '-') + '/' + "
            + "(document.body ? parseFloat(getComputedStyle(document.body).fontSize) : 0)"
        return (try? await view.evaluateJavaScript(script, contentWorld: .defaultClient) as? String) ?? "?"
    }
}
#endif
