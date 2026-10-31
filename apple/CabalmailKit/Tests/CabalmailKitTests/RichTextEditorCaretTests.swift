import XCTest
@testable import CabalmailKit

/// Edit Message in compose's laptop pose puts the caret back where it last
/// was in the editor (`focusRestoringCaret()`): the page keeps the caret's
/// last range from `selectionchange`, and drops it when `setHTML` replaces
/// what it was in. Runs against a live `WKWebView`, like
/// `RichTextEditorTextScaleTests`.
@MainActor
final class RichTextEditorCaretTests: XCTestCase {
    private var controller: RichTextEditorController!

    override func setUp() async throws {
        try await super.setUp()
        controller = RichTextEditorController(readyTimeout: 120)
        await controller.waitUntilReady()
        XCTAssertNil(controller.bridgeFailure, "editor bridge never booted in this runner")
    }

    override func tearDown() async throws {
        controller = nil
        try await super.tearDown()
    }

    @discardableResult
    private func run(_ script: String) async throws -> Any? {
        try await controller.webView.evaluateJavaScript(script)
    }

    /// Puts the caret `offset` characters into the editor's first text node,
    /// lets `selectionchange` record it, then clears the selection and blurs.
    private func placeCaretThenLeave(at offset: Int) async throws {
        try await run("""
            (function () {
              var editor = document.getElementById('editor');
              editor.focus();
              var text = editor.querySelector('p').firstChild;
              var range = document.createRange();
              range.setStart(text, \(offset));
              range.collapse(true);
              var selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
            })();
            """)
        try await Task.sleep(for: .milliseconds(50))
        try await run("window.getSelection().removeAllRanges(); document.getElementById('editor').blur();")
    }

    private func caretOffset() async throws -> Int {
        let value = try await run("""
            (function () {
              var selection = window.getSelection();
              if (!selection || selection.rangeCount === 0) return -1;
              if (document.activeElement !== document.getElementById('editor')) return -2;
              return selection.anchorOffset;
            })();
            """)
        return (value as? Int) ?? -3
    }

    func testTheCaretComesBackWhereItWas() async throws {
        try await run("window.cabal.setHTML('<p>Hello world</p>', false, '')")
        try await placeCaretThenLeave(at: 5)

        await controller.focusRestoringCaret()
        let offset = try await caretOffset()
        XCTAssertEqual(offset, 5)
    }

    func testWithNoCaretYetItLandsAtTheStart() async throws {
        try await run("window.cabal.setHTML('<p>Hello world</p>', false, '')")

        await controller.focusRestoringCaret()
        let offset = try await caretOffset()
        XCTAssertEqual(offset, 0)
    }

    /// New content drops the old caret, so no range into removed nodes
    /// comes back.
    func testNewContentDropsTheOldCaret() async throws {
        try await run("window.cabal.setHTML('<p>Hello world</p>', false, '')")
        try await placeCaretThenLeave(at: 5)
        try await run("window.cabal.setHTML('<p>Something else</p>', false, '')")

        await controller.focusRestoringCaret()
        let offset = try await caretOffset()
        XCTAssertEqual(offset, 0)
    }

    func testTheBridgeExportsIt() async throws {
        let type = try await run("typeof window.cabal.focusRestoringCaret")
        XCTAssertEqual(type as? String, "function")
    }
}
