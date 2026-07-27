import WebKit
import XCTest
@testable import Cabalmail

/// The reader web view's privacy posture: everything here is a setting whose
/// default leaks something (page JS, persistent site data, or — via link
/// preview — a silent fetch of a link's target).
@MainActor
final class ReaderWebViewConfigTests: XCTestCase {
    private func makeView() -> WKWebView {
        makeReaderWebView(coordinator: HTMLBodyCoordinator(allowRemote: false))
    }

    /// #789: the default (true) makes a long-press load the linked page even
    /// with remote content blocked.
    func testLinkPreviewIsDisabled() {
        XCTAssertFalse(makeView().allowsLinkPreview)
    }

    func testPageJavaScriptIsDisabled() {
        let view = makeView()
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
    }

    func testWebsiteDataStoreIsNonPersistent() {
        XCTAssertFalse(makeView().configuration.websiteDataStore.isPersistent)
    }
}
