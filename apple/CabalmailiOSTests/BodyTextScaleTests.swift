#if os(iOS)
import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import CabalmailUI

/// HTML message bodies follow the system text size on iOS. The macOS suite
/// (`ReaderTextScaleTests`) pins what the reader does with a scale; this one
/// pins where the scale comes from, which only an iOS host can see: the
/// Dynamic Type body ratio, read by `HTMLBodyView` from its environment.
@MainActor
final class BodyTextScaleTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    func testTheDefaultSizeIsUnscaled() {
        XCTAssertEqual(DynamicTypeSize.large.bodyTextScale, 1)
    }

    /// The ratio is the one `.body` text draws at, the font the plain-text
    /// body uses: 40pt over 17pt at `.accessibility3`. `UIFontMetrics` on a
    /// 17pt font would give 37pt there, smaller than the plain-text reader.
    func testTheScaleIsTheBodyStylesOwn() {
        XCTAssertEqual(DynamicTypeSize.accessibility3.bodyTextScale, 40.0 / 17.0, accuracy: 0.0001)
    }

    func testEveryLargerSizeScalesFurther() {
        let scales = DynamicTypeSize.allCases.map(\.bodyTextScale)
        for (smaller, larger) in zip(scales, scales.dropFirst()) {
            XCTAssertLessThan(smaller, larger)
        }
    }

    /// The reported bug, end to end: an HTML body hosted at an accessibility
    /// text size draws its author's 14px text at the scaled size. The default
    /// size is the control that it is the environment doing it.
    func testAnHTMLBodyFollowsTheEnvironmentsTextSize() async throws {
        let scaled = try await authorTextSize(at: .accessibility3)
        XCTAssertEqual(scaled, 14 * 40 / 17, accuracy: 0.01)
        let control = try await authorTextSize(at: .large)
        XCTAssertEqual(control, 14, accuracy: 0.01)
    }

    private func authorTextSize(at size: DynamicTypeSize) async throws -> Double {
        let body = HTMLBodyView(
            html: "<p id=\"p\" style=\"font-size:14px\">Text the sender sized.</p>",
            inlineImages: [:], allowRemote: false, readerMode: false
        )
        .environment(AppState())
        .environment(\.dynamicTypeSize, size)
        window?.isHidden = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIHostingController(rootView: body)
        window.isHidden = false
        self.window = window
        let webView = try await firstWebView(in: window)
        // The page's own size until the load, and the scaling script with it,
        // has run; the scaled size once it has.
        var reading: Double?
        for _ in 0..<500 {
            reading = try await webView.evaluateJavaScript(
                "(function(){ var p = document.getElementById('p'); return p && document.readyState === 'complete'"
                    + " ? parseFloat(getComputedStyle(p).fontSize) : null; })()",
                contentWorld: .defaultClient) as? Double
            if reading != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(reading, "the body never loaded")
    }

    private func firstWebView(in window: UIWindow) async throws -> WKWebView {
        for _ in 0..<300 {
            window.layoutIfNeeded()
            if let found = Self.webView(in: window) { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("SwiftUI never mounted the web view")
        throw CancellationError()
    }

    private static func webView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = webView(in: child) { return found }
        }
        return nil
    }
}
#endif
