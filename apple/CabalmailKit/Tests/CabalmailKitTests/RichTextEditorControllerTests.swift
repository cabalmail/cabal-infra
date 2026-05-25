import XCTest
@testable import CabalmailKit

/// Conversion-rule tests. The Apple-side composer must produce the same wire
/// HTML / Markdown bytes as the React composer, so the rules baked into
/// `editor-bridge.js` (marked with `breaks: true` + flattenParagraphs, the
/// turndown ZWSP-trick paragraph + line-break rules, the styleParagraphs
/// regex) are exercised end-to-end against a live `WKWebView`-backed
/// controller — same code path the user hits at send time.
@MainActor
final class RichTextEditorControllerTests: XCTestCase {
    private var controller: RichTextEditorController!

    override func setUp() async throws {
        try await super.setUp()
        controller = RichTextEditorController()
        await controller.waitUntilReady()
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    // MARK: - Markdown -> HTML

    func testMarkdownToHtmlSingleParagraph() async {
        let html = await controller.markdownToHtml("Hello world")
        XCTAssertEqual(html, "<p>Hello world</p>\n")
    }

    /// Blank-line-separated paragraphs collapse to a single <p> with
    /// <br><br> between them — the flattenParagraphs rule.
    func testMarkdownToHtmlMultipleParagraphsFlattens() async {
        let html = await controller.markdownToHtml("Para 1\n\nPara 2")
        XCTAssertEqual(html, "<p>Para 1<br><br>Para 2</p>\n")
    }

    /// `breaks: true` => single newline becomes <br>, not a space.
    func testMarkdownToHtmlSingleNewlineBecomesBr() async {
        let html = await controller.markdownToHtml("Line A\nLine B")
        XCTAssertEqual(html, "<p>Line A<br>Line B</p>\n")
    }

    func testMarkdownToHtmlHeadings() async {
        let html = await controller.markdownToHtml("# Heading")
        XCTAssertTrue(html.contains("<h1>Heading</h1>"), "got: \(html)")
    }

    // MARK: - HTML -> Markdown

    func testHtmlToMarkdownStripsParagraphMargins() async {
        let markdown = await controller.htmlToMarkdown(
            "<p>Para 1</p><p>Para 2</p>"
        )
        // Each <p> emits content + \n; turndown's outer trim eats the
        // trailing newline — no blank lines around paragraphs.
        XCTAssertEqual(markdown, "Para 1\nPara 2")
    }

    /// Two consecutive <br>s must accumulate two newlines (this is what the
    /// ZWSP placeholder trick exists for — without it turndown collapses
    /// adjacent newlines).
    func testHtmlToMarkdownConsecutiveBrAccumulates() async {
        let markdown = await controller.htmlToMarkdown("<p>One<br><br>Two</p>")
        XCTAssertEqual(markdown, "One\n\nTwo")
    }

    func testHtmlToMarkdownAtxHeading() async {
        let markdown = await controller.htmlToMarkdown("<h1>Title</h1>")
        XCTAssertTrue(markdown.hasPrefix("# Title"), "got: \(markdown)")
    }

    func testHtmlToMarkdownHorizontalRuleIsTripleDash() async {
        let markdown = await controller.htmlToMarkdown("<p>Above</p><hr><p>Below</p>")
        XCTAssertTrue(markdown.contains("---"), "got: \(markdown)")
    }

    /// ZWSP placeholders that turndown emits are stripped before return.
    func testHtmlToMarkdownStripsZeroWidthSpace() async {
        let markdown = await controller.htmlToMarkdown("<p>Hello</p>")
        XCTAssertFalse(markdown.contains("\u{200B}"), "ZWSP leaked: \(markdown)")
    }

    // MARK: - styleParagraphs

    func testStyleParagraphsAddsMarginZero() async {
        let styled = await controller.styleParagraphs("<p>Hello</p>")
        XCTAssertEqual(styled, "<p style=\"margin:0\">Hello</p>")
    }

    /// styleParagraphs must respect an existing style attribute — leave it
    /// alone rather than double-stamping a margin:0.
    func testStyleParagraphsSkipsExistingStyle() async {
        let input = "<p style=\"color:red\">Hello</p>"
        let styled = await controller.styleParagraphs(input)
        XCTAssertEqual(styled, input)
    }

    func testStyleParagraphsPreservesOtherAttributes() async {
        let styled = await controller.styleParagraphs("<p class=\"foo\">Hi</p>")
        XCTAssertEqual(styled, "<p class=\"foo\" style=\"margin:0\">Hi</p>")
    }

    // MARK: - Editor surface

    func testEditorRoundTripsSetHtmlGetHtml() async {
        await controller.setHTML("<p>Hello there</p>")
        let read = await controller.getHTML()
        XCTAssertEqual(read, "<p>Hello there</p>")
    }

    func testEmptyEditorReportsEmpty() async {
        await controller.setHTML("")
        let empty = await controller.isEmpty()
        XCTAssertTrue(empty)
    }

    func testEditorWithContentReportsNonEmpty() async {
        await controller.setHTML("<p>Hello</p>")
        let empty = await controller.isEmpty()
        XCTAssertFalse(empty)
    }

    // MARK: - Round-trips

    /// Source of truth: round-tripping markdown through the editor produces
    /// the same markdown back out. This is the property the React composer
    /// relies on so a user toggling Rich Text -> Markdown -> Rich Text never
    /// surprises themselves with whitespace shifts.
    func testMarkdownRoundTrip() async {
        let cases = [
            "Hello world",
            "Para 1\n\nPara 2",
            "Line A\nLine B",
            "# Heading\n\nBody"
        ]
        for source in cases {
            let html = await controller.markdownToHtml(source)
            let back = await controller.htmlToMarkdown(html)
            XCTAssertEqual(back, source, "round-trip drift on: \(source.debugDescription)")
        }
    }

    /// styleParagraphs applied on top of a flattened markdown render shapes
    /// the wire HTML the recipient ultimately sees — single-spaced
    /// paragraphs, exactly what the React composer ships.
    func testWireShapeForMarkdownOnlyCompose() async {
        let raw = await controller.markdownToHtml("Para 1\n\nPara 2")
        let styled = await controller.styleParagraphs(raw)
        XCTAssertEqual(styled, "<p style=\"margin:0\">Para 1<br><br>Para 2</p>\n")
    }
}
