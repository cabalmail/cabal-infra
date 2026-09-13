import WebKit
import XCTest
@testable import Cabalmail

/// The reader's scroll bridge against a real `WKWebView`: with page-content
/// JavaScript disabled, the app-injected user script must still observe
/// scrolling and post the anchor through the message handler. Loads a tall
/// page into the same configuration the reader uses, scrolls it from the
/// native side, and waits for a capture. Off-screen, so a window is attached
/// only to give WebKit a layout to scroll.
@MainActor
final class ReaderScrollBridgeTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        super.tearDown()
    }

    private func loadedReader(
        coordinator: HTMLBodyCoordinator, readerMode: Bool = true
    ) async throws -> WKWebView {
        let view = makeReaderWebView(coordinator: coordinator)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = view
        let paragraphs = (1...80).map { "<p id=\"p\($0)\">Paragraph \($0) of a long article.</p>" }.joined()
        coordinator.render(html: "<html><body>\(paragraphs)</body></html>", inlineImages: [:],
                           allowRemote: false, readerMode: readerMode, on: view)
        for _ in 0..<400 where !coordinator.didFinishLoad {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.didFinishLoad, "page never finished loading")
        return view
    }

    private func waitForCapture(
        _ captures: @escaping () -> [ScrollCapture], where predicate: (ScrollCapture) -> Bool
    ) async throws -> ScrollCapture? {
        for _ in 0..<300 {
            if let hit = captures().last(where: predicate) { return hit }
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func testScrollingPostsAnAnchorThroughTheBridge() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        var captures: [ScrollCapture] = []
        coordinator.onScrollCaptured = { captures.append($0) }
        let view = try await loadedReader(coordinator: coordinator)
        view.evaluateJavaScript("window.scrollTo(0, 900)", completionHandler: nil)
        // Well inside the 2 s poll interval: only the bridge can deliver this.
        let deadline = Date().addingTimeInterval(1.5)
        var hit: ScrollCapture?
        while Date() < deadline, hit == nil {
            hit = captures.last { !$0.isAtTop }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(hit, "no scrolled capture arrived within 1.5 s; the bridge did not fire")
        // Reader styling pads the body; the probe must still find the
        // paragraph under the viewport top, not fall back to a fraction
        // (which drifts as images load).
        XCTAssertEqual(hit?.anchor.first, "i", "anchor should name an element, got \(hit?.anchor ?? "nil")")
    }

    func testAnchorNamesAnElementInOriginalStylingToo() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        var captures: [ScrollCapture] = []
        coordinator.onScrollCaptured = { captures.append($0) }
        let view = try await loadedReader(coordinator: coordinator, readerMode: false)
        view.evaluateJavaScript("window.scrollTo(0, 900)", completionHandler: nil)
        let hit = try await waitForCapture({ captures }, where: { !$0.isAtTop })
        XCTAssertEqual(hit?.anchor.first, "i", "got \(hit?.anchor ?? "nil")")
    }

    /// The anchor restores to the same element: capture after a scroll,
    /// reload the page, apply the anchor, and the same paragraph is at the
    /// top of the viewport.
    func testCapturedAnchorRestoresTheSameElement() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        var captures: [ScrollCapture] = []
        coordinator.onScrollCaptured = { captures.append($0) }
        let view = try await loadedReader(coordinator: coordinator)
        view.evaluateJavaScript("window.scrollTo(0, 900)", completionHandler: nil)
        guard let hit = try await waitForCapture({ captures }, where: { !$0.isAtTop }) else {
            return XCTFail("no capture")
        }
        let idBefore = try await view.evaluateJavaScript(
            "(function(){var el=document.elementFromPoint(200,1);return el?el.id:''})()") as? String
        view.evaluateJavaScript("window.scrollTo(0, 0)", completionHandler: nil)
        _ = try await waitForCapture({ captures }, where: { $0.isAtTop })
        view.evaluateJavaScript(HTMLBodyCoordinator.restoreScript(anchor: hit.anchor), completionHandler: nil)
        _ = try await waitForCapture({ captures }, where: { !$0.isAtTop })
        let idAfter = try await view.evaluateJavaScript(
            "(function(){var el=document.elementFromPoint(200,1);return el?el.id:''})()") as? String
        XCTAssertFalse(idBefore?.isEmpty ?? true)
        XCTAssertEqual(idBefore, idAfter)
    }

    func testScrollingBackToTheTopReportsAtTop() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        var captures: [ScrollCapture] = []
        coordinator.onScrollCaptured = { captures.append($0) }
        let view = try await loadedReader(coordinator: coordinator)
        view.evaluateJavaScript("window.scrollTo(0, 900)", completionHandler: nil)
        let scrolled = try await waitForCapture({ captures }, where: { !$0.isAtTop })
        XCTAssertNotNil(scrolled)
        view.evaluateJavaScript("window.scrollTo(0, 0)", completionHandler: nil)
        let top = try await waitForCapture({ captures }, where: { $0.isAtTop })
        XCTAssertNotNil(top, "returning to the top should report atTop so the cache clears")
    }
}
