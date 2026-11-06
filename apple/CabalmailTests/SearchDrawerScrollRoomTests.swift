import XCTest
@testable import CabalmailUI

// The compact folder and feed lists' search drawer could be pulled into view
// but never pushed back out when the rows didn't fill the screen: UIKit tucks
// the drawer away only when the list can scroll by the drawer's height.
// `SearchDrawerScrollRoom` pads the list to its tallest viewport, which these
// pin with the iPhone 17 numbers the fix was measured against (669 pt
// viewport with the drawer tucked, 615 pt with it shown, 83 pt tab-bar inset).
final class SearchDrawerScrollRoomTests: XCTestCase {

    /// With the drawer shown the viewport is the shorter one, and the margin
    /// still fills the tallest: the list can scroll by the drawer's height,
    /// which is what lets a push tuck it away.
    func testShortListGetsRoomToScrollTheDrawerAway() {
        let margin = SearchDrawerScrollRoom.bottomMargin(tallestViewport: 669, rowsHeight: 416, insets: 83)
        XCTAssertEqual(margin, 170)
        let shownViewport: CGFloat = 615
        XCTAssertEqual(416 + margin + 83 - shownViewport, 54, "scroll range equals the drawer's height")
    }

    /// With the drawer tucked away the padded list exactly fits: no scroll
    /// range left, so the rows can't be pushed up under the filter pills.
    func testTuckedDrawerLeavesNoScrollRange() {
        let margin = SearchDrawerScrollRoom.bottomMargin(tallestViewport: 669, rowsHeight: 416, insets: 83)
        XCTAssertEqual(416 + margin + 83, 669)
    }

    /// A list that already overflows scrolls the drawer away on its own and
    /// gets no padding.
    func testLongListGetsNoMargin() {
        XCTAssertEqual(SearchDrawerScrollRoom.bottomMargin(tallestViewport: 669, rowsHeight: 1800, insets: 83), 0)
    }

    /// Only iOS draws `.searchable` as a scroll-driven drawer; the Mac's
    /// sidebar field and visionOS keep their lists unpadded.
    func testOnlyIOSPadsForTheDrawer() {
        XCTAssertTrue(HostPlatform.iOS.searchDrawerFollowsScroll)
        XCTAssertFalse(HostPlatform.macOS.searchDrawerFollowsScroll)
        XCTAssertFalse(HostPlatform.visionOS.searchDrawerFollowsScroll)
    }
}
