import XCTest
#if canImport(WebKit)
@testable import CabalmailKit

/// Bridge-liveness tests (#745).
///
/// Most of these drive the handshake directly through `handleBridgeMessage` /
/// the navigation-delegate callback and assert on what happens when the
/// bridge *doesn't* come up, or dies after it has. Every one of them ends
/// with a `waitUntilReady()` that must return — before the fix those awaits
/// parked forever and Send spun with no error and no timeout.
///
/// The exception is `testRealEditorPageBootsInThisRunner`, which asserts the
/// premise the conversion suite depends on: that `editor.html` really boots
/// in whatever runner is executing — a runner that cannot host the editor
/// fails by name rather than quietly taking the conversion tests down with
/// it (#948). The one sanctioned exception is apple.yml's simulator
/// WebContent carve-out: CI's freshly created iOS/visionOS devices never
/// launch a WebContent process under a hostless runner, so those legs skip
/// this test (and the conversion suite) explicitly and loudly, and the
/// macOS leg carries the coverage.
@MainActor
final class RichTextEditorBridgeHealthTests: XCTestCase {
    /// The #734 shape: the boot script fails, so `ready` never arrives.
    /// The error is posted synchronously right after `init`, before any
    /// suspension point lets a (hosted) real load report ready.
    func testBootScriptErrorReleasesWaiters() async {
        let controller = RichTextEditorController(readyTimeout: 600)
        var reported: String?
        controller.onBridgeError = { reported = $0 }

        controller.handleBridgeMessage([
            "type": "error",
            "message": "failed to load editor-bridge.js"
        ])

        XCTAssertEqual(controller.bridgeFailure, "failed to load editor-bridge.js")
        XCTAssertFalse(controller.isReady)
        XCTAssertEqual(reported, "failed to load editor-bridge.js")
        // The deadline is 10 minutes out, so a wait that returns here was
        // released by the failure, not by the timeout.
        await controller.waitUntilReady()
    }

    /// The shape the tester reproduced on device: the content process is
    /// killed *after* boot. `isReady` used to stay true forever, so nothing
    /// was waiting — every conversion just answered "" and the send went
    /// out empty.
    func testContentProcessTerminationMarksBridgeUnusable() async {
        let controller = RichTextEditorController(readyTimeout: 600)
        var reported: String?
        controller.handleBridgeMessage(["type": "ready"])
        XCTAssertTrue(controller.isReady)
        controller.onBridgeError = { reported = $0 }

        controller.webViewWebContentProcessDidTerminate(controller.webView)

        XCTAssertFalse(controller.isReady)
        XCTAssertNotNil(controller.bridgeFailure)
        XCTAssertNotNil(reported)
        await controller.waitUntilReady()
    }

    /// A script error *after* the bridge is live is forwarded but not fatal —
    /// the composer keeps working, so a stray page error can't strand a
    /// message the user can otherwise send.
    func testPostReadyScriptErrorDoesNotDisableTheBridge() {
        let controller = RichTextEditorController(readyTimeout: 600)
        var reported: String?
        controller.handleBridgeMessage(["type": "ready"])
        controller.onBridgeError = { reported = $0 }

        controller.handleBridgeMessage(["type": "error", "message": "stray"])

        XCTAssertEqual(reported, "stray")
        XCTAssertNil(controller.bridgeFailure)
        XCTAssertTrue(controller.isReady)
    }

    /// A `ready` that lands after the deadline fired means the boot was slow,
    /// not dead: the failure clears and the composer goes on using it.
    func testLateReadyClearsTheFailure() {
        let controller = RichTextEditorController(readyTimeout: 600)
        controller.webViewWebContentProcessDidTerminate(controller.webView)
        XCTAssertNotNil(controller.bridgeFailure)

        controller.handleBridgeMessage(["type": "ready"])

        XCTAssertNil(controller.bridgeFailure)
        XCTAssertTrue(controller.isReady)
    }

    /// The real `file://` load, end to end: no injected messages, just the
    /// page booting and posting `ready`. This is what the conversion suite
    /// assumed and never checked — it skipped itself instead, on the theory
    /// that an unhosted `xctest` process cannot bootstrap a WKWebView, and
    /// so nothing noticed that the theory was wrong (#948).
    func testRealEditorPageBootsInThisRunner() async {
        // Same generous deadline the conversion suite uses: a cold simulator
        // needs more than the 10s production default for its first boot.
        let controller = RichTextEditorController(readyTimeout: 120)

        await controller.waitUntilReady()

        XCTAssertNil(controller.bridgeFailure, "editor bridge never booted in this runner")
        XCTAssertTrue(controller.isReady)
        // Ready is the handshake; this is the page actually answering.
        let html = await controller.markdownToHtml("Hello world")
        XCTAssertEqual(html, "<p>Hello world</p>\n")
    }

    /// The deadline itself. Hosted (`xcodebuild test`) the real page may well
    /// boot first, so the assertion is the disjunction — what must hold
    /// either way is that the wait *returns*, which is the whole bug.
    func testWaitUntilReadyIsBounded() async {
        let controller = RichTextEditorController(readyTimeout: 0.25)

        await controller.waitUntilReady()

        XCTAssertTrue(
            controller.isReady || controller.bridgeFailure != nil,
            "wait returned without either outcome recorded"
        )
    }

    /// The `focus` / `blur` bridge messages drive `isEditorFocused`, which
    /// hosts use to scope editor-directed shortcuts (the iPad ⌘⇧V
    /// paste-without-formatting route) to the editor actually having focus.
    func testFocusMessagesTrackEditorFocus() {
        let controller = RichTextEditorController(readyTimeout: 600)
        var observed: [Bool] = []
        controller.onEditorFocusChanged = { observed.append($0) }
        XCTAssertFalse(controller.isEditorFocused)

        controller.handleBridgeMessage(["type": "focus"])
        XCTAssertTrue(controller.isEditorFocused)

        controller.handleBridgeMessage(["type": "blur"])
        XCTAssertFalse(controller.isEditorFocused)
        XCTAssertEqual(observed, [true, false])
    }
}
#endif
