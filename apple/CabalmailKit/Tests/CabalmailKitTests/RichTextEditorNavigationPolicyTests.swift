#if canImport(WebKit)
import WebKit
import XCTest
@testable import CabalmailKit

/// The composer's navigation policy (only the editor's own file load is
/// allowed; every link is cancelled) runs only while WebKit can see it. Under
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
}
#endif
