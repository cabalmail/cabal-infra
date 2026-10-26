import XCTest
@testable import CabalmailKit

/// The composer follows the system text size (#2187): the app layer hands
/// the editor `DynamicTypeSize.bodyTextScale` through `setTextScale(_:)`,
/// and the page scales its 14px base by it. The scale is display only, so
/// the HTML `/send` and `/save_draft` receive is the same at every size.
/// Runs against a live `WKWebView`, like `RichTextEditorControllerTests`.
@MainActor
final class RichTextEditorTextScaleTests: XCTestCase {
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

    private func editorFontSize() async throws -> String {
        let value = try await controller.webView.evaluateJavaScript(
            "getComputedStyle(document.getElementById('editor')).fontSize"
        )
        return value as? String ?? ""
    }

    func testDefaultSizeIsTheFourteenPixelBase() async throws {
        let size = try await editorFontSize()
        XCTAssertEqual(size, "14px")
    }

    func testScaleEnlargesTheEditorText() async throws {
        await controller.setTextScale(2)
        let doubled = try await editorFontSize()
        XCTAssertEqual(doubled, "28px")
        // The accessibility3 body ratio (40 / 17), a fraction rather than a
        // whole number, reaches the page too.
        await controller.setTextScale(40.0 / 17.0)
        let size = try await editorFontSize()
        let pixels = Double(size.replacingOccurrences(of: "px", with: "")) ?? 0
        XCTAssertEqual(pixels, 14 * 40 / 17, accuracy: 0.01, "got \(size)")
    }

    func testScaleOfOneRestoresTheBase() async throws {
        await controller.setTextScale(2)
        await controller.setTextScale(1)
        let size = try await editorFontSize()
        XCTAssertEqual(size, "14px")
    }

    /// A ratio that is not a positive number resets rather than collapsing
    /// the text to nothing.
    func testNonPositiveScaleResetsToTheBase() async throws {
        await controller.setTextScale(2)
        await controller.setTextScale(0)
        let size = try await editorFontSize()
        XCTAssertEqual(size, "14px")
    }

    /// The wire HTML carries no trace of the display scale.
    func testScaleNeverReachesTheWireHtml() async throws {
        await controller.setHTML("<p>Hello world</p>")
        let before = await controller.getHTML()
        await controller.setTextScale(2)
        let scaled = try await editorFontSize()
        XCTAssertEqual(scaled, "28px", "the scale has to apply for this to say anything")
        let after = await controller.getHTML()
        XCTAssertEqual(after, before)
        XCTAssertFalse(after.contains("font-size"), "got: \(after)")
    }
}
