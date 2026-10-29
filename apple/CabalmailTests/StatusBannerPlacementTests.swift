import XCTest
@testable import CabalmailUI

// The status banners moved from the top of the window to the bottom in #1426,
// so what this file pins moved with them.
//
// The old rule (#931, #958) was "clear the navigation bar": at regular width
// the banner covered New Message, Addresses and the search field, and at
// compact width it covered the centre title slot carrying the folder name.
// Both were real and both are now unreachable — a banner anchored to the
// bottom cannot cover the top band at all — so those two cases are retired
// rather than kept passing against a constant nothing reads.
//
// What replaces them is the same shape of claim about the other end of the
// window: the one thing in the bottom band is the compact-width tab bar.
final class StatusBannerPlacementTests: XCTestCase {

    /// iPhone 17 frames, measured live for #1426: the window is 874pt tall and
    /// the tab bar occupies {{0, 791}, {402, 83}}. The overlay's own bottom
    /// edge is not the window's bottom safe area — with the shipped inset the
    /// banner's close button measured {{314.7, 741.7}, {15, 15}}, which puts
    /// the overlay's edge at about y 822.
    private let compactWindowHeight: CGFloat = 874
    private let compactOverlayBottom: CGFloat = 822
    private let compactTabBarTop: CGFloat = 791

    func testCompactWidthBannersClearTheTabBar() {
        let bannerBottom = compactOverlayBottom
            - StatusBannerPlacement.bottomInset(isRegularWidth: false)
        XCTAssertLessThan(
            bannerBottom, compactTabBarTop,
            "a banner ending inside the tab bar's band covers Mail / Folders / Search"
        )
    }

    /// …and not so far above it that it climbs back into the message list it
    /// was moved out of. The first message row starts at y 154 on the same
    /// device, so anything in the lower third is comfortably clear; this pins
    /// the inset as a small clearance rather than an open-ended lift.
    func testCompactWidthBannersStayNearTheBottom() {
        let bannerBottom = compactOverlayBottom
            - StatusBannerPlacement.bottomInset(isRegularWidth: false)
        XCTAssertGreaterThan(bannerBottom, compactWindowHeight * 0.75)
    }

    func testPlatformsWithoutATabBarInTheBandKeepThePlainGap() {
        // iPad, macOS and visionOS draw no tab bar across the window's bottom
        // (visionOS's is an ornament outside it), and macOS/visionOS bypass
        // `bottomInset(isRegularWidth:)` entirely to read this constant — so
        // nothing above may quietly lift their banners off the window edge.
        XCTAssertEqual(StatusBannerPlacement.defaultBottomInset, 6)
        XCTAssertEqual(StatusBannerPlacement.bottomInset(isRegularWidth: true), 6)
    }
}

/// The iPhone Duo fold rule: nothing on the crease, a banner with the column
/// that raised it in book pose, nothing tappable above a laptop fold.
/// Geometry from the open Duo's 951 x 667 pt overlay.
final class StatusBannerFoldPlacementTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 951, height: 667)
    private let left = CGRect(x: 0, y: 0, width: 455, height: 667)
    private let right = CGRect(x: 495, y: 0, width: 456, height: 667)
    private let top = CGRect(x: 0, y: 0, width: 951, height: 313)
    private let bottom = CGRect(x: 0, y: 353, width: 951, height: 314)
    private let columns: [Toast.Column?] = [nil, .list, .reader]

    func testWithNoFoldEveryBannerTakesTheWholeOverlay() {
        for column in columns {
            for hasControls in [false, true] {
                let slot = StatusBannerPlacement.slot(in: .whole(bounds), column: column, hasControls: hasControls)
                XCTAssertEqual(slot, .whole)
                XCTAssertEqual(StatusBannerPlacement.frame(of: slot, in: .whole(bounds)), bounds)
            }
        }
    }

    func testInBookPoseABannerSitsWithTheColumnThatRaisedIt() {
        let pieces = FoldPieces.sideBySide(leading: left, trailing: right)
        for hasControls in [false, true] {
            XCTAssertEqual(StatusBannerPlacement.slot(in: pieces, column: .list, hasControls: hasControls),
                           .leadingPiece)
            XCTAssertEqual(StatusBannerPlacement.slot(in: pieces, column: .reader, hasControls: hasControls),
                           .trailingPiece)
            XCTAssertEqual(StatusBannerPlacement.slot(in: pieces, column: nil, hasControls: hasControls),
                           .trailingPiece, "the window's own banners sit with the reader")
        }
        XCTAssertEqual(StatusBannerPlacement.frame(of: .leadingPiece, in: pieces), left)
        XCTAssertEqual(StatusBannerPlacement.frame(of: .trailingPiece, in: pieces), right)
    }

    func testInLaptopPoseNothingTappableSitsAboveTheFold() {
        let pieces = FoldPieces.stacked(top: top, bottom: bottom)
        for column in columns {
            XCTAssertEqual(StatusBannerPlacement.slot(in: pieces, column: column, hasControls: true), .belowCrease)
            XCTAssertEqual(StatusBannerPlacement.slot(in: pieces, column: column, hasControls: false), .aboveCrease)
        }
        XCTAssertEqual(StatusBannerPlacement.frame(of: .aboveCrease, in: pieces), top)
        XCTAssertEqual(StatusBannerPlacement.frame(of: .belowCrease, in: pieces), bottom)
    }

    func testASlotFromAnotherFoldHasNoFrame() {
        XCTAssertNil(StatusBannerPlacement.frame(of: .leadingPiece, in: .whole(bounds)))
        XCTAssertNil(StatusBannerPlacement.frame(of: .aboveCrease, in: .sideBySide(leading: left, trailing: right)))
        XCTAssertNil(StatusBannerPlacement.frame(of: .whole, in: .stacked(top: top, bottom: bottom)))
    }

    /// Above a laptop fold the crease is the banners' floor, with no bar in
    /// between; everywhere else they keep the window's own bottom inset.
    func testOnlyBannersOnACreaseDropTheWindowsBottomInset() {
        let window = StatusBannerPlacement.compactWidthBottomInset
        XCTAssertEqual(StatusBannerPlacement.bottomInset(of: .aboveCrease, windowBottomInset: window),
                       StatusBannerPlacement.defaultBottomInset)
        for slot in [StatusBannerPlacement.Slot.whole, .leadingPiece, .trailingPiece, .belowCrease] {
            XCTAssertEqual(StatusBannerPlacement.bottomInset(of: slot, windowBottomInset: window), window)
        }
    }

    /// A toast's column counts only in the window that raised it; any other
    /// window shows it as the window's own.
    func testAToastsColumnCountsOnlyInItsOwnWindow() {
        let here = UUID()
        let raised = Toast(kind: .info, message: "x", origin: Toast.Origin(window: here, column: .list))
        XCTAssertEqual(raised.column(in: here), .list)
        XCTAssertNil(raised.column(in: UUID()))
        XCTAssertNil(raised.column(in: nil))
        XCTAssertNil(Toast(kind: .info, message: "x").column(in: here))
    }
}
