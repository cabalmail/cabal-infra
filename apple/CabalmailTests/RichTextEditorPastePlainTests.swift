import XCTest
import WebKit
import CabalmailKit
@testable import Cabalmail

/// Paste-without-formatting (⌘⇧V) behaviour of the editor page.
///
/// These live in the app-layer suite rather than CabalmailKitTests because
/// WKWebView needs an app host to load editor.html — the Kit suite's
/// editor tests skip under the hostless `xctest` runner, and this suite is
/// the one place the bridge actually boots during a test run.
@MainActor
final class RichTextEditorPastePlainTests: XCTestCase {
    private var controller: RichTextEditorController!

    override func setUp() async throws {
        try await super.setUp()
        controller = RichTextEditorController()
        await controller.waitUntilReady()
        try XCTSkipIf(
            controller.bridgeFailure != nil,
            "editor bridge failed to boot: \(controller.bridgeFailure ?? "")"
        )
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    /// Drives `window.cabal.insertPlainText` the way the `pastePlain`
    /// bridge round-trip does after native reads the pasteboard: markup in
    /// the clipboard text must land escaped (literal, unformatted) and
    /// newlines become <br>, matching the plain-flavor paste path.
    func testInsertPlainTextEscapesMarkupAndBreaksLines() async throws {
        let html = try await controller.webView.evaluateJavaScript(
            """
            (function () {
              const editor = document.getElementById('editor');
              editor.focus();
              const range = document.createRange();
              range.selectNodeContents(editor);
              range.collapse(false);
              const sel = window.getSelection();
              sel.removeAllRanges();
              sel.addRange(range);
              window.cabal.insertPlainText('A <b>bold</b>\\nB');
              return editor.innerHTML;
            })()
            """
        ) as? String
        XCTAssertNotNil(html)
        XCTAssertTrue(
            html?.contains("A &lt;b&gt;bold&lt;/b&gt;<br>B") == true,
            "got: \(html ?? "nil")"
        )
    }

    /// A non-string argument (empty pasteboard edge) must not throw or
    /// modify the editor.
    func testInsertPlainTextIgnoresNonString() async throws {
        await controller.setHTML("<p>Keep</p>")
        _ = try await controller.webView.evaluateJavaScript(
            "window.cabal.insertPlainText(null); true"
        )
        let read = await controller.getHTML()
        XCTAssertEqual(read, "<p>Keep</p>")
    }

    /// ⌘⇧V is claimed by the editor page itself (it posts `pastePlain` to
    /// native), so WebKit must see the keydown consumed.
    func testCmdShiftVKeydownIsIntercepted() async throws {
        let prevented = try await controller.webView.evaluateJavaScript(
            """
            (function () {
              const event = new KeyboardEvent('keydown', {
                key: 'V', code: 'KeyV', metaKey: true, shiftKey: true,
                cancelable: true, bubbles: true
              });
              document.getElementById('editor').dispatchEvent(event);
              return event.defaultPrevented;
            })()
            """
        ) as? Bool
        XCTAssertEqual(prevented, true)
    }

    #if os(macOS)
    /// End-to-end on macOS: a real ⌘⇧V NSEvent through the webview's
    /// key-equivalent path must reach the editor page with its modifier
    /// flags intact, round-trip through the `pastePlain` bridge message,
    /// and land the pasteboard's plain-text flavor — escaped — in the
    /// editor. This is the actual hardware-keyboard path; the synthetic
    /// KeyboardEvent tests above only cover the JS handler in isolation.
    func testHardwareCmdShiftVPastesPlainText() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.webView
        window.makeFirstResponder(controller.webView)
        await controller.focusAtStart()

        // Seed the pasteboard with a marker, restoring whatever was there
        // so a local test run doesn't eat the user's clipboard.
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let marker = "cabal-test <b>literal</b>\nsecond line"
        pasteboard.clearContents()
        pasteboard.setString(marker, forType: .string)

        let chord = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "V",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9  // kVK_ANSI_V
        ))
        _ = controller.webView.performKeyEquivalent(with: chord)

        // The key event, the bridge message, and the insertion are all
        // asynchronous — poll the editor until the marker shows up.
        let expected = "cabal-test &lt;b&gt;literal&lt;/b&gt;<br>second line"
        var html = ""
        for _ in 0..<40 {
            html = await controller.getHTML()
            if html.contains(expected) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(html.contains(expected), "editor HTML after chord: \(html)")
    }
    #endif

    /// Plain ⌘V must stay untouched so WebKit's normal paste flow (and the
    /// paste listener's HTML-flavor handling) still runs.
    func testPlainCmdVKeydownIsNotIntercepted() async throws {
        let prevented = try await controller.webView.evaluateJavaScript(
            """
            (function () {
              const event = new KeyboardEvent('keydown', {
                key: 'v', code: 'KeyV', metaKey: true,
                cancelable: true, bubbles: true
              });
              document.getElementById('editor').dispatchEvent(event);
              return event.defaultPrevented;
            })()
            """
        ) as? Bool
        XCTAssertEqual(prevented, false)
    }
}
