import XCTest
@testable import CabalmailKit

/// Conversion-rule tests. The Apple-side composer must produce the same wire
/// HTML / Markdown bytes as the React composer, so the rules baked into
/// `editor-bridge.js` (marked with `breaks: true` + flattenParagraphs, the
/// turndown ZWSP-trick paragraph + line-break rules, the styleParagraphs
/// regex) are exercised end-to-end against a live `WKWebView`-backed
/// controller — same code path the user hits at send time. A local `file://`
/// load needs no app host (#948), so this runs under `swift test` and on any
/// booted simulator — but NOT on CI's freshly `simctl create`d iOS/visionOS
/// devices, which never launch a WebContent process under a hostless runner;
/// apple.yml carves this suite out on those legs and the macOS leg carries
/// the coverage.
@MainActor
final class RichTextEditorControllerTests: XCTestCase {
    private var controller: RichTextEditorController!

    override func setUp() async throws {
        try await super.setUp()
        // A cold simulator takes well over the controller's 10s production
        // readyTimeout to boot its first WebContent process (measured 12.6s
        // on a freshly booted iPhone 17 Pro sim). Past the deadline every
        // bridge call answers with its empty fallback, so the suite would
        // fail on `""` comparisons that say nothing about conversion rules —
        // give the boot room, and assert the bridge came up here so a
        // runner that genuinely cannot host it fails by name instead.
        controller = RichTextEditorController(readyTimeout: 120)
        await controller.waitUntilReady()
        XCTAssertNil(controller.bridgeFailure, "editor bridge never booted in this runner")
        XCTAssertTrue(controller.isReady)
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

    /// Select-all + delete does not empty the element. WebKit keeps the
    /// block scaffolding, and on a document that had paragraphs in it —
    /// which is every compose with a signature, a reply or a resumed draft
    /// — what is left is `<p><br></p>`. `isEmpty()` used to match only
    /// `''`, `'<p></p>'` and `'<br>'`, so `getHTML()` handed those 12
    /// characters to the send path as authored copy and the composer went
    /// on asking "Discard draft?" over a visibly empty pane (#1138).
    func testClearedParagraphScaffoldingReportsEmpty() async {
        for residue in ["<p><br></p>", "<br>", "<p></p>", "<div><br></div>", "<p><br></p><p><br></p>"] {
            await controller.setHTML(residue)
            let empty = await controller.isEmpty()
            XCTAssertTrue(empty, "\(residue) is scaffolding, not content")
            let html = await controller.getHTML()
            XCTAssertEqual(html, "", "\(residue) must not reach the wire")
        }
    }

    /// Whitespace-only is the same answer, and matches how the Markdown
    /// pane is already read (`ComposeBodyPolicy.source` trims before
    /// deciding whether that buffer is filled).
    func testWhitespaceOnlyBodyReportsEmpty() async {
        await controller.setHTML("<p>   </p>")
        let empty = await controller.isEmpty()
        XCTAssertTrue(empty)
    }

    /// The negative control the text-based test needs: content that carries
    /// no text at all still counts, so an image-only or rule-only body is
    /// never silently dropped.
    func testNonTextContentIsNotEmpty() async {
        for markup in ["<p><img src=\"cid:x\"></p>", "<hr>"] {
            await controller.setHTML(markup)
            let empty = await controller.isEmpty()
            XCTAssertFalse(empty, "\(markup) is content")
        }
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
