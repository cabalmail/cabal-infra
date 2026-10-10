import XCTest
@testable import CabalmailUI

/// Which selection path the message list takes, by the window's shell
/// (#1985). The iPad split's list column reports a compact size class, which
/// put the iPad list on the iPhone path: no arrow keys or ⌘A, no shift- or
/// ⌘-click, no "N Messages Selected" in Select mode, and rows that couldn't
/// be dragged to the folder panel. The shell is what tells the split apart
/// from the tabs.
final class MessageListLayoutTests: XCTestCase {

    func testTheIPadSplitTakesTheMacsPath() {
        XCTAssertTrue(MessageListLayout.isWide(in: .split))
    }

    func testTheMacTakesTheWidePath() {
        XCTAssertTrue(MessageListLayout.isWide(in: .desktop))
    }

    /// visionOS's Mail tab shows the list beside the reader, as the split
    /// does.
    func testTheOrnamentsListSitsBesideItsReader() {
        XCTAssertTrue(MessageListLayout.isWide(in: .ornament))
    }

    /// The tabs push the reader over the list, so the list keeps the touch
    /// path: single selection, Select mode, per-row menus, no drag.
    func testTheTabsKeepTheTouchPath() {
        XCTAssertFalse(MessageListLayout.isWide(in: .tabs))
    }

    /// Every layout an iPad window can be in, from the size classes up:
    /// regular in both is the split and the wide path; narrowed to compact
    /// is the tabs and the touch path.
    func testAnIPadWindowSwitchesPathWithItsShell() {
        let wide = ShellLayout.resolve(on: .iOS, isCompactWidth: false, isCompactHeight: false, measuredWidth: 1194)
        let narrow = ShellLayout.resolve(on: .iOS, isCompactWidth: true, isCompactHeight: false, measuredWidth: 507)
        XCTAssertTrue(MessageListLayout.isWide(in: wide))
        XCTAssertFalse(MessageListLayout.isWide(in: narrow))
    }
}
