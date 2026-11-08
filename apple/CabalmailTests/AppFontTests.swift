import AppKit
import SwiftUI
import XCTest
@testable import CabalmailUI

/// The Mac's interface text size (`AppTextSize`, through `appFont(_:)`):
/// the default is exactly the text style, other steps scale the platform
/// size for the style in its own weight, nothing shrinks past the floor,
/// and the scene root carries the size (and a default font) to its views.
@MainActor
final class AppFontTests: XCTestCase {
    private static let styles: [Font.TextStyle] = [
        .largeTitle, .title, .title2, .title3, .headline, .subheadline,
        .body, .callout, .footnote, .caption, .caption2,
    ]
    private var savedInterface: AppTextSize = .medium

    override func setUp() async throws {
        try await super.setUp()
        savedInterface = AppTextSizeStore.shared.interface
    }

    override func tearDown() async throws {
        AppTextSizeStore.shared.interface = savedInterface
        try await super.tearDown()
    }

    /// At the default size the helper is the text style itself, so the
    /// migration from `.font(.caption)` changes nothing anyone sees.
    func testMediumIsTheTextStyleItself() {
        for style in Self.styles {
            XCTAssertEqual(Font.app(style, .medium), .system(style))
            XCTAssertEqual(Font.app(style, .medium, weight: .semibold), Font.system(style).weight(.semibold))
            XCTAssertEqual(Font.app(style, .medium, monospaced: true), Font.system(style).monospaced())
            XCTAssertEqual(Font.app(style, .medium, monospacedDigit: true), Font.system(style).monospacedDigit())
            XCTAssertEqual(height(of: Text("Hg").appFont(style)), height(of: Text("Hg").font(.system(style))),
                           "\(style) draws differently at the default size")
        }
    }

    /// A step up draws every style taller, a step down no taller, and the
    /// styles keep their order: a caption stays smaller than the body and
    /// the body smaller than a title.
    func testStepsScaleEveryStyleAndKeepTheirOrder() {
        for style in Self.styles {
            let medium = height(of: Text("Hg").appFont(style), at: .medium)
            XCTAssertGreaterThan(height(of: Text("Hg").appFont(style), at: .xLarge), medium, "\(style)")
            XCTAssertLessThanOrEqual(height(of: Text("Hg").appFont(style), at: .xSmall), medium, "\(style)")
        }
        XCTAssertLessThan(height(of: Text("Hg").appFont(.title), at: .xSmall),
                          height(of: Text("Hg").appFont(.title), at: .medium))
        for size in AppTextSize.allCases {
            let caption = height(of: Text("Hg").appFont(.caption), at: size)
            let body = height(of: Text("Hg").appFont(.body), at: size)
            let title = height(of: Text("Hg").appFont(.title), at: size)
            XCTAssertLessThan(caption, body, "\(size)")
            XCTAssertLessThan(body, title, "\(size)")
        }
    }

    /// A scaled headline keeps the headline's bold weight: on the Mac the
    /// headline and the body share a point size, so only the weight tells
    /// them apart.
    func testScaledHeadlineKeepsItsWeight() {
        let text = "Weight check, wide enough to tell"
        XCTAssertEqual(Font.platformPointSize(for: .headline), Font.platformPointSize(for: .body))
        XCTAssertGreaterThan(width(of: Text(text).appFont(.headline), at: .large),
                             width(of: Text(text).appFont(.body), at: .large))
    }

    /// Nothing shrinks below 9pt, and text already smaller keeps its size.
    func testStepDownStopsAtTheFloor() {
        XCTAssertEqual(Font.scaledPointSize(10, .xSmall), 9)
        XCTAssertEqual(Font.scaledPointSize(8, .xSmall), 8)
        XCTAssertEqual(Font.scaledPointSize(13, .xSmall), 13 * AppTextSize.xSmall.scale, accuracy: 0.001)
        XCTAssertEqual(Font.scaledPointSize(13, .xLarge), 13 * AppTextSize.xLarge.scale, accuracy: 0.001)
    }

    /// The message list's one row height follows the interface size in
    /// whole points, and is the base itself at the default.
    func testMessageRowHeightFollowsTheSize() {
        XCTAssertEqual(MessageListView.rowHeight(base: 58, at: .medium), 58)
        XCTAssertEqual(MessageListView.rowHeight(base: 58.4, at: .medium), 58.4)
        XCTAssertEqual(MessageListView.rowHeight(base: 58, at: .xLarge), 75)
        XCTAssertEqual(MessageListView.rowHeight(base: 58, at: .xSmall), 49)
        for size in AppTextSize.allCases {
            let height = MessageListView.rowHeight(base: 58, at: size)
            XCTAssertEqual(height, height.rounded(), "\(size)")
        }
    }

    /// The scene root hands its views the stored interface size and gives
    /// text that names no font the body at that size; at the default it
    /// sets no font at all. A bare view, outside the root, is the control.
    func testSceneRootCarriesTheInterfaceSize() async throws {
        AppTextSizeStore.shared.interface = .medium
        let plain = height(of: Text("Hg"))
        let rooted = SizeBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VStack {
            InterfaceProbe(box: rooted).appTextSize()
            InterfaceProbe(box: SizeBox())
        })
        defer { window.contentView = nil }
        try await waitFor { rooted.size == .medium }
        XCTAssertEqual(height(of: Text("Hg").appTextSize()), plain)

        AppTextSizeStore.shared.interface = .xLarge
        try await waitFor { rooted.size == .xLarge }
        XCTAssertGreaterThan(height(of: Text("Hg").appTextSize()), plain)
        XCTAssertEqual(height(of: Text("Hg")), plain, "without the root the default applies")
    }

    /// The interface size has its own stored value, apart from the
    /// message-text size.
    func testStoreKeepsTheInterfaceSizeApart() throws {
        let suite = "AppFontTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(AppTextSize.interfaceDefaultsKey, "cabalmail.display.interface_text_size")

        let store = AppTextSizeStore(defaults: defaults)
        store.interface = .large
        XCTAssertEqual(defaults.string(forKey: AppTextSize.interfaceDefaultsKey), "large")
        XCTAssertNil(defaults.string(forKey: AppTextSize.contentDefaultsKey))
        let reread = AppTextSizeStore(defaults: defaults)
        XCTAssertEqual(reread.interface, .large)
        XCTAssertEqual(reread.content, .medium)
    }

    // MARK: - Measuring

    private func height(of view: some View, at size: AppTextSize? = nil) -> CGFloat {
        fitting(view, at: size).height
    }

    private func width(of view: some View, at size: AppTextSize? = nil) -> CGFloat {
        fitting(view, at: size).width
    }

    private func fitting(_ view: some View, at size: AppTextSize?) -> CGSize {
        let host: NSView
        if let size {
            host = NSHostingView(rootView: view.environment(\.interfaceTextSize, size).fixedSize())
        } else {
            host = NSHostingView(rootView: view.fixedSize())
        }
        return host.fittingSize
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath,
                         line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "condition not met in time", file: file, line: line)
    }
}

@MainActor
private final class SizeBox {
    var size: AppTextSize?
}

private struct InterfaceProbe: View {
    let box: SizeBox
    @Environment(\.interfaceTextSize) private var size

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = (box.size = size)
        Color.clear.frame(width: 10, height: 10)
    }
}
