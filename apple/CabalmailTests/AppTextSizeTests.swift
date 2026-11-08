import AppKit
import SwiftUI
import XCTest
@testable import CabalmailUI

/// The Mac's message-text size (`AppTextSize`): the ramp, the steps the
/// View menu's ⌘+ / ⌘− walk, and the path from the stored value through a
/// scene root (`appTextSize()`) to the scale the readers and composer draw
/// at (`contentTextScale`) and the plain-text body's font.
@MainActor
final class AppTextSizeTests: XCTestCase {
    private let key = AppTextSize.contentDefaultsKey
    private var savedValue: Any?

    override func setUp() async throws {
        try await super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(savedValue, forKey: key)
        try await super.tearDown()
    }

    /// `.medium` is the size from before the setting, so it must scale by
    /// exactly 1, and the ramp must grow strictly from bottom to top.
    func testMediumIsTheOldSizeAndTheRampGrows() {
        XCTAssertEqual(AppTextSize.medium.scale, 1)
        let scales = AppTextSize.allCases.map(\.scale)
        XCTAssertEqual(scales, scales.sorted())
        XCTAssertEqual(Set(scales).count, scales.count)
        XCTAssertEqual(AppTextSize.allCases.first, .xSmall)
        XCTAssertEqual(AppTextSize.allCases.last, .xLarge)
    }

    /// The stored strings are what an existing install reads back.
    func testStoredValuesAreStable() {
        XCTAssertEqual(AppTextSize.allCases.map(\.rawValue),
                       ["x_small", "small", "medium", "large", "x_large"])
        XCTAssertEqual(AppTextSize.contentDefaultsKey, "cabalmail.display.content_text_size")
    }

    /// ⌘+ and ⌘− step one place along the ramp and stop at its ends.
    func testStepsWalkTheRampAndStopAtTheEnds() {
        XCTAssertEqual(AppTextSize.medium.larger, .large)
        XCTAssertEqual(AppTextSize.large.larger, .xLarge)
        XCTAssertNil(AppTextSize.xLarge.larger)
        XCTAssertEqual(AppTextSize.medium.smaller, .small)
        XCTAssertEqual(AppTextSize.small.smaller, .xSmall)
        XCTAssertNil(AppTextSize.xSmall.smaller)
        for size in AppTextSize.allCases {
            if let larger = size.larger { XCTAssertEqual(larger.smaller, size) }
        }
    }

    /// The setting is offered only where there is no system text size.
    func testOnlyTheMacOffersTheSetting() {
        XCTAssertTrue(HostPlatform.macOS.offersAppTextSize)
        XCTAssertFalse(HostPlatform.iOS.offersAppTextSize)
        XCTAssertFalse(HostPlatform.visionOS.offersAppTextSize)
        XCTAssertFalse(HostPlatform.watchOS.offersAppTextSize)
    }

    /// The scale the readers draw at is the message-text size's scale (the
    /// Mac has no Dynamic Type, so that factor is 1 here).
    func testContentScaleFollowsTheSize() {
        var environment = EnvironmentValues()
        XCTAssertEqual(environment.contentTextScale, 1)
        environment.contentTextSize = .xLarge
        XCTAssertEqual(environment.contentTextScale, AppTextSize.xLarge.scale)
        environment.contentTextSize = .xSmall
        XCTAssertEqual(environment.contentTextScale, AppTextSize.xSmall.scale)
    }

    /// The plain-text body stays on `.body` at the default and draws at the
    /// body size times the scale otherwise.
    func testPlainTextBodyFont() {
        XCTAssertEqual(Font.contentBody(.medium), .body)
        let base = NSFont.preferredFont(forTextStyle: .body).pointSize
        XCTAssertEqual(Font.contentBody(.large), .system(size: base * AppTextSize.large.scale))
        XCTAssertNotEqual(Font.contentBody(.large), .body)
    }

    /// A scene root hands its views the stored size, and a change to the
    /// stored value (what the View menu and Settings write) reaches them
    /// without the scene being rebuilt. Without `appTextSize()` the probe
    /// reads the `.medium` default, which the negative control pins.
    func testSceneRootDeliversTheStoredSize() async throws {
        UserDefaults.standard.set(AppTextSize.large.rawValue, forKey: key)
        let rooted = SizeBox()
        let bare = SizeBox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VStack {
            SizeProbe(box: rooted).appTextSize()
            SizeProbe(box: bare)
        })
        defer { window.contentView = nil }

        try await waitFor { rooted.size == .large }
        XCTAssertEqual(bare.size, .medium, "without the root modifier the default applies")

        UserDefaults.standard.set(AppTextSize.xSmall.rawValue, forKey: key)
        try await waitFor { rooted.size == .xSmall }
        XCTAssertEqual(bare.size, .medium)
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

private struct SizeProbe: View {
    let box: SizeBox
    @Environment(\.contentTextSize) private var size

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = (box.size = size)
        Color.clear.frame(width: 10, height: 10)
    }
}
