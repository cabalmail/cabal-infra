import XCTest
@testable import CabalmailUI

/// Pins that the buttons on the split's column-scoped bars carry a TITLE,
/// not just an icon and an `accessibilityLabel`.
///
/// What a crowded bar folds an item into is a menu row, and a row built from
/// a bare `Image` has nothing to draw: measured on an iPad Pro 11-inch at
/// 834 pt with the addresses inspector squeezing the list column to 220 pt,
/// New Message was absent from the bar AND from the `•••` overflow, while
/// the More menu — whose label is a `Label("More", systemImage:)` — folded
/// and stayed reachable. Titling the button put it back in the overflow as a
/// row of its own (#1787).
///
/// Nothing renders a bar in a unit test, so this scans the source, the way
/// `ToolbarVisibilitySourceScanTests` scans the ranking wiring beside it.
final class ToolbarOverflowTitleSourceScanTests: XCTestCase {

    func testTheListsComposeButtonIsTitled() throws {
        let branch = try Self.touchBranchOfTheListToolbar()
        XCTAssertTrue(
            branch.contains(#"Label("New Message", systemImage: "square.and.pencil")"#),
            "the touch platforms' Compose button needs a title to survive folding"
        )
    }

    func testTheListsComposeButtonIsNotIconOnly() throws {
        // The negative control: the shape this replaced. An
        // `accessibilityLabel` is read, not drawn, so it does not answer for
        // the title — a revert to it would pass the test above only if that
        // test were scanning the wrong thing.
        let branch = try Self.touchBranchOfTheListToolbar()
        XCTAssertFalse(branch.contains(#"Image(systemName: "square.and.pencil")"#))
        XCTAssertFalse(branch.contains(#".accessibilityLabel("New Message")"#))
    }

    func testTheAddressInspectorToggleIsTitled() throws {
        // The `@` toggle shares the bar and loses the same way: reported
        // absent from a 714 pt Stage Manager window's bar (#1787's thread).
        let body = try Self.source("CabalmailUI/Shell/WideMail.swift")
        XCTAssertTrue(body.contains(#"Label("Addresses", systemImage: "at")"#))
        XCTAssertFalse(body.contains(#"Image(systemName: "at")"#))
    }

    func testTheFeedListsComposeButtonIsTitled() throws {
        // The feed twin of the mail list, in the same column, on the same
        // bar.
        let body = try Self.source("CabalmailUI/Feeds/ItemList/FeedItemListView.swift")
        XCTAssertTrue(body.contains(#"Label("New Message", systemImage: "square.and.pencil")"#))
        XCTAssertFalse(body.contains(#"Image(systemName: "square.and.pencil")"#))
    }

    /// The `#else` arm of the list toolbar's platform split — the touch
    /// platforms' Compose item. Scoped, because the macOS arm above it still
    /// declares an icon-only button: the Mac's bar spans the window and its
    /// crowding (the `»` popup, #1047) was not measured here.
    private static func touchBranchOfTheListToolbar() throws -> String {
        let body = try source("CabalmailUI/Mail/MessageList/MessageListView.swift")
        guard let start = body.range(of: "            #else\n            ToolbarItem {"),
              let end = body.range(of: "            .keepsInBar()\n            #endif"),
              start.upperBound <= end.lowerBound else {
            // A scan whose anchor is gone fails rather than passing on an
            // empty string: a rename must not turn this into a no-op.
            throw AnchorGone.listToolbarPlatformSplit
        }
        return String(body[start.lowerBound..<end.upperBound])
    }

    private enum AnchorGone: Error {
        /// The `#if os(macOS)` / `#else` split around the list's Compose
        /// item, which this scan slices the touch arm out of.
        case listToolbarPlatformSplit
    }

    private static let apple = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CabalmailTests
        .deletingLastPathComponent()   // apple

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: apple.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
