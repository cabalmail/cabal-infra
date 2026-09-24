import XCTest
import CabalmailKit
@testable import Cabalmail

/// The one count-badge rule both sidebars read (cross-media plan, Phase 1):
/// mail folder rows and feed rows show the same thing for the same
/// `folderCountDisplay`, and a zero hides the same way on both.
final class FolderCountBadgeTests: XCTestCase {

    func testUnreadModeShowsUnreadAndHidesZero() {
        XCTAssertEqual(FolderCountBadge.text(display: .unread, unread: 4, total: 30), "4")
        XCTAssertNil(FolderCountBadge.text(display: .unread, unread: 0, total: 30))
        XCTAssertNil(FolderCountBadge.text(display: .unread, unread: nil, total: 30))
    }

    func testTotalModeShowsTotalAndHidesZero() {
        XCTAssertEqual(FolderCountBadge.text(display: .total, unread: 4, total: 30), "30")
        XCTAssertNil(FolderCountBadge.text(display: .total, unread: 4, total: 0))
        XCTAssertNil(FolderCountBadge.text(display: .total, unread: 4, total: nil))
    }

    func testBothModeShowsUnreadOverTotal() {
        XCTAssertEqual(FolderCountBadge.text(display: .both, unread: 4, total: 30), "4/30")
        // A fetched, empty folder is a real zero; the mail rows have always
        // drawn it, and a feed with nothing cached reads the same way.
        XCTAssertEqual(FolderCountBadge.text(display: .both, unread: 0, total: 0), "0/0")
        XCTAssertEqual(FolderCountBadge.text(display: .both, unread: nil, total: 30), "0/30")
    }

    /// A mail folder whose STATUS has not arrived shows nothing rather than
    /// `0/0`; feeds never pass nil, so this is the mail-only branch.
    func testBothModeHidesAnUnfetchedFolder() {
        XCTAssertNil(FolderCountBadge.text(display: .both, unread: nil, total: nil))
        XCTAssertNil(FolderCountBadge.text(display: .both, unread: 3, total: nil))
    }

    func testAccessibilityLabelFollowsTheMode() {
        XCTAssertEqual(FolderCountBadge.accessibilityLabel(display: .unread, unread: 4, total: 30), "4 unread")
        XCTAssertEqual(FolderCountBadge.accessibilityLabel(display: .total, unread: 4, total: 30), "30 items")
        XCTAssertEqual(FolderCountBadge.accessibilityLabel(display: .both, unread: 4, total: 30), "4 unread of 30")
    }

    /// A hidden badge says nothing: the label is nil exactly when the text is.
    func testAccessibilityLabelIsNilWheneverTheBadgeIsHidden() {
        for display in FolderCountDisplay.allCases {
            for unread in [nil, 0, 3] {
                for total in [nil, 0, 30] {
                    XCTAssertEqual(
                        FolderCountBadge.accessibilityLabel(display: display, unread: unread, total: total) == nil,
                        FolderCountBadge.text(display: display, unread: unread, total: total) == nil,
                        "\(display) unread=\(String(describing: unread)) total=\(String(describing: total))"
                    )
                }
            }
        }
    }
}
