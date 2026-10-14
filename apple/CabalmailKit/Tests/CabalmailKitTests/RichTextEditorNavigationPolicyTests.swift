#if canImport(WebKit)
import WebKit
import XCTest
@testable import CabalmailKit

/// The composer's navigation policy (the editor's own page loads once; every
/// other navigation is cancelled) runs only while WebKit can see it. Under
/// complete concurrency checking the completion-handler form of the method
/// stopped matching the SDK's requirement, which left it a plain Swift method
/// WebKit never calls, with only a warning to say so; this asks the
/// Objective-C runtime the question WebKit asks.
@MainActor
final class RichTextEditorNavigationPolicyTests: XCTestCase {
    func testWebKitCanSeeTheNavigationPolicy() {
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        XCTAssertTrue(
            RichTextEditorController.instancesRespond(to: selector),
            "WebKit would allow every navigation in the composer"
        )
    }

    /// The other optional delegate method, behind #745: without it a web
    /// content process that dies after `ready` goes unnoticed and a send
    /// takes an empty body.
    func testWebKitCanSeeTheContentProcessHandler() {
        let selector = NSSelectorFromString("webViewWebContentProcessDidTerminate:")
        XCTAssertTrue(RichTextEditorController.instancesRespond(to: selector))
    }

    // MARK: - The policy itself

    private let editor = URL(fileURLWithPath: "/bundle/WebAssets/editor.html")

    private func allows(
        _ url: URL?,
        type: WKNavigationType = .other,
        inMainFrame: Bool = true,
        editorPageAllowed: Bool = false
    ) -> Bool {
        RichTextEditorController.allowsNavigation(
            to: url,
            type: type,
            inMainFrame: inMainFrame,
            editorURL: editor,
            editorPageAllowed: editorPageAllowed
        )
    }

    func testTheEditorPageLoadsOnce() {
        XCTAssertTrue(allows(editor))
        XCTAssertFalse(allows(editor, editorPageAllowed: true), "a second load would wipe the draft")
    }

    /// Before, any `file://` URL loaded in the main frame.
    func testNoOtherLocalFileLoads() {
        XCTAssertFalse(allows(URL(fileURLWithPath: "/bundle/WebAssets/editor-bridge.js")))
        XCTAssertFalse(allows(URL(fileURLWithPath: "/etc/hosts")))
    }

    func testNothingElseNavigatesTheComposer() {
        XCTAssertFalse(allows(nil))
        XCTAssertFalse(allows(URL(string: "https://example.com/")))
        XCTAssertFalse(allows(URL(string: "about:blank")))
        XCTAssertFalse(allows(editor, inMainFrame: false), "no frame loads anything")
        for type in [WKNavigationType.linkActivated, .reload, .formSubmitted, .backForward, .formResubmitted] {
            XCTAssertFalse(allows(editor, type: type), "\(type.rawValue)")
        }
    }
}
#endif
