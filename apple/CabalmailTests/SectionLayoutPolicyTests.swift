import XCTest
@testable import Cabalmail

/// Pins the rule behind the iOS section layout. The regression this guards:
/// rotating a Plus / Max iPhone to landscape flips its horizontal size class
/// to regular, and a layout keyed on size class alone swapped the compact tab
/// tree for the iPad split — dropping the open feed item (and the Feeds tab
/// with it) and landing on the mail INBOX. Rotating back rebuilt the tabs at
/// the launch landing, not where the user had been.
final class SectionLayoutPolicyTests: XCTestCase {

    func testPhonePortraitUsesTabs() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isPhone: true, isCompactWidth: true),
            .compactTabs
        )
    }

    func testPhoneStaysOnTabsWhenLandscapeReportsRegularWidth() {
        // Plus / Max in landscape: regular horizontal size class, still a
        // phone. The layout must not change across the rotation, or the tab
        // tree — and everything selected inside it — is discarded.
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isPhone: true, isCompactWidth: false),
            .compactTabs
        )
    }

    func testRotationNeverChangesThePhoneLayout() {
        let portrait = SectionLayoutPolicy.layout(isPhone: true, isCompactWidth: true)
        let landscape = SectionLayoutPolicy.layout(isPhone: true, isCompactWidth: false)
        XCTAssertEqual(portrait, landscape)
    }

    func testRegularWidthPadUsesTheSplit() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isPhone: false, isCompactWidth: false),
            .regularSplit
        )
    }

    func testPhonePinsCompactWidth() {
        // The tab tree overrides the size class on a phone so the Mail tab's
        // split view never expands in landscape and collapses back — the
        // cycle behind the unpushed reader and the stranded inspector sheet.
        XCTAssertTrue(SectionLayoutPolicy.pinsCompactWidth(isPhone: true))
    }

    func testPadKeepsItsOwnSizeClass() {
        // An iPad that widens out of multitasking must be allowed to see the
        // regular size class, or it could never switch to the split layout.
        XCTAssertFalse(SectionLayoutPolicy.pinsCompactWidth(isPhone: false))
    }

    func testCompactMultitaskingPadUsesTabs() {
        XCTAssertEqual(
            SectionLayoutPolicy.layout(isPhone: false, isCompactWidth: true),
            .compactTabs
        )
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
}
