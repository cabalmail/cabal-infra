import XCTest
@testable import Cabalmail

/// Pins the rule behind the iOS section layout. Two regressions live here:
///
/// - Rotating a Plus / Max iPhone to landscape flips its horizontal size
///   class to regular, and a layout keyed on width alone swapped the compact
///   tab tree for the iPad split — dropping the open feed item (and the Feeds
///   tab with it) and landing on the mail INBOX. Rotating back rebuilt the
///   tabs at the launch landing, not where the user had been.
/// - The idiom check that fixed that pinned every phone to the tabs, and
///   iPhone Duo's inner display is a phone with a regular/regular size class.
///   It must get the split, or the 7.6-inch display draws a phone layout.
final class SectionLayoutPolicyTests: XCTestCase {

    func testPhonePortraitUsesTabs() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: false),
            .compactTabs
        )
    }

    func testPhoneStaysOnTabsWhenLandscapeReportsRegularWidth() {
        // Plus / Max in landscape: regular horizontal size class, compact
        // vertical. The layout must not change across the rotation, or the
        // tab tree — and everything selected inside it — is discarded.
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: true),
            .compactTabs
        )
    }

    func testRotationNeverChangesThePhoneLayout() {
        let portrait = SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: false)
        let landscape = SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: true)
        XCTAssertEqual(portrait, landscape)
    }

    func testCompactInBothDimensionsUsesTabs() {
        // A non-Plus iPhone in landscape, or iPhone Duo's outer display in
        // landscape ("tent" pose).
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: true),
            .compactTabs
        )
    }

    func testRegularInBothDimensionsUsesTheSplit() {
        // A regular-width iPad, or iPhone Duo's inner display. The idiom must
        // not take part: Duo reports the phone idiom.
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false),
            .regularSplit
        )
    }

    func testCompactMultitaskingPadUsesTabs() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: false),
            .compactTabs
        )
    }

    func testClosingADuoCollapsesToTabs() {
        // Inner display open: regular/regular. Closed onto the outer display:
        // compact width, regular height. The tree changes — documented and
        // intended; the selection hand-off between the trees is separate work.
        let open = SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false)
        let closed = SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: false)
        XCTAssertEqual(open, .regularSplit)
        XCTAssertEqual(closed, .compactTabs)
    }

    func testIOSReaderHidesTheSectionTabBar() {
        // The compact bottom tab bar occludes the reader's action toolbar, and
        // a swipe back to the list restores it — so hiding it stays correct.
        XCTAssertTrue(SectionLayoutPolicy.readerHidesSectionTabBar(isVisionOS: false))
    }

    func testVisionOSReaderKeepsTheSectionOrnament() {
        // visionOS draws the section `TabView` as the window's leading
        // ornament, which the reader does not compete with and which carries
        // the only entry points to Folders, Feeds, Addresses, Settings and
        // Search. Hiding it left an open message with no way back to any of
        // them, and the resume restore re-opened that message on the next
        // launch (#1627).
        XCTAssertFalse(SectionLayoutPolicy.readerHidesSectionTabBar(isVisionOS: true))
    }

    // MARK: - Measured width (#1679)

    func testRegularClassesWithNarrowStaleBoundsHoldTheTabs() {
        // iPhone Duo unfolding: traits say regular while the window is still
        // the outer display's 466 pt.
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false, measuredWidth: 466),
            .compactTabs
        )
    }

    func testRegularClassesWithRegularBoundsUseTheSplit() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false, measuredWidth: 951),
            .regularSplit
        )
    }

    func testAnUnmeasuredWindowTrustsTheSizeClasses() {
        // Cold launch: nothing has been laid out yet.
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false, measuredWidth: nil),
            .regularSplit
        )
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: false, isCompactHeight: false, measuredWidth: 0),
            .regularSplit
        )
    }

    func testAWideMeasurementNeverPromotesACompactClass() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isCompactWidth: true, isCompactHeight: false, measuredWidth: 951),
            .compactTabs
        )
    }

    func testTheFloorSitsBetweenTheWidestCompactAndNarrowestRegularWindows() {
        XCTAssertGreaterThan(SectionLayoutPolicy.regularWidthFloor, 507)
        XCTAssertLessThan(SectionLayoutPolicy.regularWidthFloor, 683)
    }
}
