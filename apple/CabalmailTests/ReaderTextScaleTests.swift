import SwiftUI
import WebKit
import XCTest
@testable import CabalmailUI

/// The HTML readers follow the system text size (`ReaderTextScale`): a
/// message or article rendered at a scale reads back, from a real
/// `WKWebView`, with its text and fixed line heights multiplied by it. The
/// scale here is passed in directly; `DynamicTypeSize.bodyTextScale` (iOS
/// suite, `BodyTextScaleTests`) is what supplies it in the app. Off-screen,
/// in a window only so WebKit lays the page out.
@MainActor
final class ReaderTextScaleTests: XCTestCase {
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

    /// Author typography of the shapes mail carries: fixed sizes and line
    /// heights inline and in a stylesheet (one `!important`), and relative
    /// sizes nested inside a fixed one.
    private static let message = """
    <html><head><style>.lead { font-size: 20px !important; line-height: 26px; }</style></head><body>
    <p id="inline" style="font-size:14px; line-height:18px">Fixed size and line height.</p>
    <p id="sheet" class="lead">Stylesheet, important.</p>
    <div style="font-size:14px">
    <span id="em" style="font-size:1.5em">Em <span id="pct" style="font-size:50%">pct</span></span>
    </div>
    <p id="unitless" style="font-size:16px; line-height:1.5">Unitless line height.</p>
    </body></html>
    """

    private func render(
        _ html: String = message, readerMode: Bool = false, textScale: Double,
        coordinator: HTMLBodyCoordinator = HTMLBodyCoordinator(allowRemote: false),
        into view: WKWebView? = nil
    ) async throws -> WKWebView {
        let view = view ?? makeReaderWebView(coordinator: coordinator)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = view
        coordinator.didFinishLoad = false
        coordinator.render(html: html, inlineImages: [:], allowRemote: false, readerMode: readerMode,
                           textScale: textScale, on: view)
        for _ in 0..<400 where !coordinator.didFinishLoad {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(coordinator.didFinishLoad, "page never finished loading")
        return view
    }

    /// `font-size/line-height` of the element with `id`, in CSS pixels.
    private func metrics(_ id: String, in view: WKWebView) async throws -> String {
        let script = """
        (function(){ var s = getComputedStyle(document.getElementById("\(id)"));
          var lh = /px$/.test(s.lineHeight) ? parseFloat(s.lineHeight) : s.lineHeight;
          return parseFloat(s.fontSize) + "/" + lh; })()
        """
        return try await view.evaluateJavaScript(script, contentWorld: .defaultClient) as? String ?? "<none>"
    }

    // MARK: - Mail reader

    func testOriginalStylingScalesTheAuthorsTextAndFixedLineHeights() async throws {
        let view = try await render(textScale: 2)
        let inline = try await metrics("inline", in: view)
        let sheet = try await metrics("sheet", in: view)
        XCTAssertEqual(inline, "28/36", "a fixed line height that kept 18px would overlap 28px text")
        XCTAssertEqual(sheet, "40/52")
    }

    /// Every size is read before any is written, so a relative size scales
    /// once, from its parent's original size, not again through the parent's
    /// scaled one (which would give 84px and 84px here).
    func testRelativeSizesScaleOnce() async throws {
        let view = try await render(textScale: 2)
        let ems = try await metrics("em", in: view)
        let pct = try await metrics("pct", in: view)
        let unitless = try await metrics("unitless", in: view)
        XCTAssertTrue(ems.hasPrefix("42/"), ems)
        XCTAssertTrue(pct.hasPrefix("21/"), pct)
        XCTAssertEqual(unitless, "32/48")
    }

    /// The control: at the default size "Original" is exactly the author's,
    /// and the document carries no scale.
    func testTheDefaultSizeLeavesTheAuthorsTypographyAlone() async throws {
        let view = try await render(textScale: 1)
        let inline = try await metrics("inline", in: view)
        let sheet = try await metrics("sheet", in: view)
        let ems = try await metrics("em", in: view)
        XCTAssertEqual(inline, "14/18")
        XCTAssertEqual(sheet, "20/26")
        XCTAssertTrue(ems.hasPrefix("21/"), ems)
        let meta = try await view.evaluateJavaScript(
            "document.querySelectorAll('meta[name=\"\(ReaderTextScale.metaName)\"]').length",
            contentWorld: .defaultClient) as? Int
        XCTAssertEqual(meta, 0)
    }

    /// Reader mode's 17px body, and the author's own sizes inside it, follow
    /// the scale too; the width cap widens with the text.
    func testReaderModeFollowsTheScale() async throws {
        let view = try await render(readerMode: true, textScale: 2)
        let body = try await view.evaluateJavaScript(
            "parseFloat(getComputedStyle(document.body).fontSize) + '/' + getComputedStyle(document.body).maxWidth",
            contentWorld: .defaultClient) as? String
        let inline = try await metrics("inline", in: view)
        XCTAssertEqual(body, "34/1360px")
        XCTAssertEqual(inline, "28/36")
    }

    /// A system text size change renders the message again at the new size.
    func testANewScaleRendersAgain() async throws {
        let coordinator = HTMLBodyCoordinator(allowRemote: false)
        let view = try await render(textScale: 2, coordinator: coordinator)
        let scaled = try await metrics("inline", in: view)
        XCTAssertEqual(scaled, "28/36")
        _ = try await render(textScale: 1, coordinator: coordinator, into: view)
        let restored = try await metrics("inline", in: view)
        XCTAssertEqual(restored, "14/18")
    }

    /// Text inside an SVG is part of a drawing whose geometry doesn't grow;
    /// the paragraph beside it still scales.
    func testSvgTextIsLeftAlone() async throws {
        let html = "<p id=\"html\" style=\"font-size:12px\">x</p>"
            + "<svg width=\"100\" height=\"20\"><text id=\"svg\" style=\"font-size:12px\">t</text></svg>"
        let view = try await render(html, textScale: 2)
        let paragraph = try await metrics("html", in: view)
        let svg = try await metrics("svg", in: view)
        XCTAssertTrue(paragraph.hasPrefix("24/"), paragraph)
        XCTAssertTrue(svg.hasPrefix("12/"), svg)
    }

    // MARK: - Feed reader

    /// The article reader's document refuses page script (#1911); the scaling
    /// script is the app's, in its own world, and still runs. Extracts a real
    /// page through the coordinator, then changes the text size under it.
    func testTheArticleReaderFollowsTheScale() async throws {
        let sentence = "A sentence that reads like an article's body text. "
        let paragraph = "<p>" + String(repeating: sentence, count: 20) + "</p>"
        let page = "<html><head><title>T</title></head><body><article><h1>T</h1>\(paragraph)\(paragraph)"
            + "</article></body></html>"
        let url = try XCTUnwrap(URL(string: "data:text/html;charset=utf-8,"
            + (page.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")))
        let coordinator = ArticleWebCoordinator(onFailure: { _ in })
        let view = coordinator.makeWebView(url: url, dataStoreID: nil)
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
        window.contentView = view

        // Extraction waits for the live page to finish loading by itself.
        coordinator.apply(readerMode: true, textScale: 2, on: view)
        try await waitUntil { try await self.bodySize(in: view) == 34 }
        coordinator.apply(readerMode: true, textScale: 1, on: view)
        try await waitUntil { try await self.bodySize(in: view) == 17 }
    }

    /// The body's font size: the live page's is WebKit's 16px default, the
    /// reader document's its stylesheet's 17px times the scale.
    private func bodySize(in view: WKWebView) async throws -> Double? {
        let script = "document.body ? parseFloat(getComputedStyle(document.body).fontSize) : null"
        return try await view.evaluateJavaScript(script, contentWorld: .defaultClient) as? Double
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    // MARK: - Scale

    /// macOS has no Dynamic Type; the Mac reader keeps its 17px.
    func testTheMacReaderKeepsItsOwnSize() {
        for size in DynamicTypeSize.allCases {
            XCTAssertEqual(size.bodyTextScale, 1, "\(size)")
        }
    }
}
