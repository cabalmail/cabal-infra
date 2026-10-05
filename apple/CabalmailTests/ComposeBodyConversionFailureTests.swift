import XCTest
import WebKit
import CabalmailKit
@testable import CabalmailUI

/// Compose behaviour when one body conversion fails on a live editor bridge.
///
/// The send path refused only when `bridgeFailure` was set (#745): a bridge
/// that never booted, or whose content process died. One call failing while
/// the bridge stayed up got the lenient API's `""`, and the message went out
/// built from it — text beside an empty HTML part from the Markdown pane,
/// the reverse from the rich pane, and, when `getHTML` failed, whatever the
/// Markdown pane was seeded with instead of what the user typed. The server
/// now drops an empty MIME part, but it cannot tell a seed from a reply.
///
/// These boot the real editor page, break one `window.cabal` method, and
/// assert on what reaches the wire. Each has a healthy-bridge control, so a
/// quiet transport means the guard held, not that the fixture never sends.
@MainActor
final class ComposeBodyConversionFailureTests: XCTestCase {

    // MARK: - Controls

    func testMarkdownPaneSendCarriesBothParts() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.markdownBody = "Hello from the Markdown pane"

        let sent = await model.send()

        XCTAssertTrue(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.endpoint), ["send"])
        XCTAssertEqual(calls.first?.text, "Hello from the Markdown pane")
        let html = try XCTUnwrap(calls.first?.html)
        XCTAssertTrue(html.contains("Hello from the Markdown pane"), html)
    }

    func testAutosaveOnAHealthyBridgeReachesTheServer() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.markdownBody = "Hello from the Markdown pane"

        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.endpoint), ["save_draft"])
        XCTAssertEqual(calls.first?.text, "Hello from the Markdown pane")
    }

    // MARK: - Send

    /// The delivered shape: before the fix this sent the Markdown as the
    /// text part beside `html: ""`.
    ///
    /// A throwing method also raises a page error, which reaches the model
    /// through `onBridgeError` on its own schedule. So these assert what
    /// holds either way — nothing on the wire, an error on screen — and
    /// leave the banner's wording to the test after them.
    func testMarkdownPaneSendRefusesWhenMarkdownToHtmlFails() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.markdownBody = "Hello from the Markdown pane"
        try await breakBridgeMethod("markdownToHtml", in: model)

        let sent = await model.send()

        XCTAssertFalse(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls, [], "nothing may reach /send without an HTML part")
        XCTAssertNotNil(model.errorMessage)
    }

    /// A call that fails without a page error (here, one that answers
    /// something other than text) could be a one-off, so the refusal says
    /// to try again and leaves Send on offer rather than raising the
    /// dead-editor banner.
    func testAOneOffFailureLeavesSendOnOffer() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.markdownBody = "Hello from the Markdown pane"
        try await breakBridgeMethod("markdownToHtml", in: model, body: "return 42;")

        let sent = await model.send()

        XCTAssertFalse(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls, [])
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertTrue(message.contains("markdownToHtml"), message)
        XCTAssertTrue(message.contains("nothing was sent"), message)
        XCTAssertNil(model.editorController.bridgeFailure)
        XCTAssertNil(model.editorUnavailable)
        XCTAssertTrue(model.canSend)
    }

    /// The mirror image: before the fix this sent `text: ""` beside the
    /// rich pane's HTML, so a plain-text reader showed a blank body.
    func testRichPaneSendRefusesWhenHtmlToMarkdownFails() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        await typeIntoRichPane("<p>Typed in the rich pane</p>", in: model)
        try await breakBridgeMethod("htmlToMarkdown", in: model)

        let sent = await model.send()

        XCTAssertFalse(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls, [])
        XCTAssertNotNil(model.errorMessage)
    }

    /// The worst case: a failed `getHTML` read as an empty rich pane, so the
    /// send fell through to the Markdown pane and delivered its seed — here
    /// a quoted original — in place of the reply typed above it.
    func testSendRefusesWhenGetHTMLFailsRatherThanSendingTheSeed() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(
            transport: transport,
            seed: Draft(body: "> the quoted original")
        )
        await typeIntoRichPane("<p>My reply</p><p>&gt; the quoted original</p>", in: model)
        try await breakBridgeMethod("getHTML", in: model)

        let sent = await model.send()

        XCTAssertFalse(sent)
        let calls = await transport.calls
        XCTAssertEqual(calls, [], "the seed must not go out in place of the reply")
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - Drafts

    /// Before the fix the tick pushed the same text-beside-`html: ""` body
    /// over the server copy.
    func testAutosaveSkipsWhenAConversionFails() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.markdownBody = "Hello from the Markdown pane"
        try await breakBridgeMethod("markdownToHtml", in: model)

        await model.autosaveToServer()

        let calls = await transport.calls
        XCTAssertEqual(calls, [])
    }

    /// Before the fix a failed `getHTML` read as an empty body with a
    /// subject, so Cancel saved a blank draft over the server copy of what
    /// the user had typed. It now closes the way a dead bridge does.
    func testCancelKeepsTheServerCopyWhenAConversionFails() async throws {
        let transport = BodyRecordingTransport()
        let model = try await makeModel(transport: transport)
        model.serverDraftRef = DraftServerRef(uid: 785, uidValidity: 9)
        await typeIntoRichPane("<p>Typed in the rich pane</p>", in: model)
        try await breakBridgeMethod("getHTML", in: model)

        let closed = await model.cancel()

        XCTAssertTrue(closed)
        let calls = await transport.calls
        XCTAssertEqual(calls, [], "neither a blank save over the server copy nor a discard of it")
        XCTAssertFalse(model.didDiscardServerDraft)
    }

    // MARK: - Fixtures

    /// A composer filled in far enough to send, on an editor bridge that
    /// has booted — or a skip that says it didn't, as the paste suite does.
    private func makeModel(
        transport: BodyRecordingTransport,
        seed: Draft = Draft()
    ) async throws -> ComposeViewModel {
        let model = try TestFixtures.makeComposeModel(seed: seed, transport: transport)
        model.fromAddress = "daily@cabalmail.example"
        model.subject = "body-conversion probe"
        model.toText = "someone@example.com"
        await model.editorController.waitUntilReady()
        try XCTSkipIf(
            model.editorController.bridgeFailure != nil,
            "editor bridge failed to boot: \(model.editorController.bridgeFailure ?? "")"
        )
        return model
    }

    /// Loads `html` into the rich pane and marks it authored, which is what
    /// the first keystroke there does (`onContentChanged`).
    private func typeIntoRichPane(_ html: String, in model: ComposeViewModel) async {
        await model.editorController.setHTML(html)
        model.richMirrorsMarkdown = false
    }

    /// Replaces one `window.cabal` method so that calls to it fail. By
    /// default it throws, the way a page-side exception fails a call.
    private func breakBridgeMethod(
        _ method: String,
        in model: ComposeViewModel,
        body: String = "throw new Error('probe');"
    ) async throws {
        _ = try await model.editorController.webView.evaluateJavaScript(
            "window.cabal.\(method) = function () { \(body) }; true"
        )
    }
}

/// Records the body of every `/send` and `/save_draft` and answers 200.
private actor BodyRecordingTransport: HTTPTransport {
    struct Call: Equatable, Sendable {
        /// `send` or `save_draft`.
        let endpoint: String
        let text: String?
        let html: String?
    }

    private(set) var calls: [Call] = []

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
            as? [String: Any] ?? [:]
        let endpoint = request.url?.lastPathComponent ?? ""
        calls.append(Call(endpoint: endpoint, text: json["text"] as? String, html: json["html"] as? String))
        let body: [String: Any] = endpoint == "save_draft"
            ? ["status": "ok", "uid": 786, "uidvalidity": 9, "replaced": true]
            : ["status": "ok"]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}
