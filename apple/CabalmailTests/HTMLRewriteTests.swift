import XCTest
@testable import Cabalmail

/// Covers the viewport meta both render paths depend on (without it WebKit
/// lays messages out at 980pt and scales them down) and the `cid:` rewriting
/// that predates it.
final class HTMLRewriteTests: XCTestCase {
    private let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"

    // MARK: - Viewport injection

    func testOriginalModeInjectsViewport() {
        let html = "<html><head><title>hi</title></head><body>two words</body></html>"
        let result = rewrite(html: html, inlineImages: [:], readerMode: false)
        XCTAssertTrue(result.contains(viewport))
    }

    func testReaderModeStillInjectsViewport() {
        let result = rewrite(html: "<body>hi</body>", inlineImages: [:], readerMode: true)
        XCTAssertTrue(result.contains(viewport))
    }

    func testViewportLandsInsideHead() {
        let html = "<html><head><title>hi</title></head><body>hi</body></html>"
        let result = rewrite(html: html, inlineImages: [:], readerMode: false)
        XCTAssertEqual(result, "<html><head>\(viewport)<title>hi</title></head><body>hi</body></html>")
    }

    /// A doctype has to stay first or the author's page renders in quirks
    /// mode — the one thing "Original" mode must not change.
    func testDoctypeStaysFirstWhenThereIsNoHead() {
        let html = "<!DOCTYPE html>\n<body>hi</body>"
        let result = rewrite(html: html, inlineImages: [:], readerMode: false)
        XCTAssertTrue(result.hasPrefix("<!DOCTYPE html>\(viewport)"), result)
    }

    func testViewportGoesAfterHtmlTagWhenThereIsNoHead() {
        let html = "<html><body>hi</body></html>"
        let result = rewrite(html: html, inlineImages: [:], readerMode: false)
        XCTAssertEqual(result, "<html>\(viewport)<body>hi</body></html>")
    }

    /// The HTML alternative our own `/send` Lambda generates is a bare
    /// fragment — the shape the tester hit in #787.
    func testBareFragmentIsPrefixed() {
        let result = rewrite(html: "<p>two words</p>", inlineImages: [:], readerMode: false)
        XCTAssertEqual(result, "\(viewport)<p>two words</p>")
    }

    /// Ours is a default, not an override: a sender's own viewport must come
    /// later in document order so WebKit honors theirs.
    func testSenderViewportSurvivesAndWins() throws {
        let sender = "<meta name=\"viewport\" content=\"width=600\">"
        let html = "<html><head>\(sender)</head><body>hi</body></html>"
        let result = rewrite(html: html, inlineImages: [:], readerMode: false)
        let ours = try XCTUnwrap(result.range(of: viewport))
        let theirs = try XCTUnwrap(result.range(of: sender))
        XCTAssertTrue(ours.lowerBound < theirs.lowerBound, result)
    }

    // MARK: - cid: rewriting

    func testRewritesInlineImageReferencesCaseInsensitively() {
        let url = URL(string: "data:image/png;base64,AAA")!
        let html = "<img src=\"cid:LogoPart\"><img src=\"CID:LogoPart\">"
        let result = rewrite(html: html, inlineImages: ["LogoPart": url], readerMode: false)
        XCTAssertFalse(result.lowercased().contains("cid:"))
        XCTAssertEqual(result.components(separatedBy: url.absoluteString).count - 1, 2)
    }
}
