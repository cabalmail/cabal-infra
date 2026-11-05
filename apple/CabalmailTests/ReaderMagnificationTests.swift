import WebKit
import XCTest
@testable import CabalmailUI

/// Pinch-to-zoom in the Mac readers. `WKWebView.allowsMagnification` is false
/// by default on macOS, so a trackpad or touch-display pinch did nothing in
/// the mail reader or the feed article view; iOS zooms both already.
/// Off-screen, in a window only so WebKit lays the page out.
@MainActor
final class ReaderMagnificationTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    }

    override func tearDown() async throws {
        window.contentView = nil
        window = nil
        try await super.tearDown()
    }

    func testTheMailReaderZooms() {
        let view = makeReaderWebView(coordinator: HTMLBodyCoordinator(allowRemote: false))
        XCTAssertTrue(view.allowsMagnification)
    }

    func testTheArticleViewZooms() throws {
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let coordinator = ArticleWebCoordinator(onFailure: { _ in }, onLeftReader: {})
        XCTAssertTrue(coordinator.makeWebView(url: url, dataStoreID: nil).allowsMagnification)
    }

    /// The reader keeps one web view as the selection moves between messages,
    /// so a zoom left on one message must not carry over to the next.
    func testTheNextMessageOpensUnzoomed() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        let view = makeReaderWebView(coordinator: coordinator)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = view

        try await render("<p>First message</p>", coordinator: coordinator, on: view)
        view.magnification = 2
        XCTAssertEqual(view.magnification, 2, accuracy: 0.01)

        try await render("<p>Second message</p>", coordinator: coordinator, on: view)
        XCTAssertEqual(view.magnification, 1, accuracy: 0.01)
    }

    private func render(_ html: String, coordinator: HTMLBodyCoordinator, on view: WKWebView) async throws {
        coordinator.didFinishLoad = false
        coordinator.render(html: html, inlineImages: [:], allowRemote: false, readerMode: false, on: view)
        for _ in 0..<400 where !coordinator.didFinishLoad {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.didFinishLoad, "page never finished loading")
    }
}
