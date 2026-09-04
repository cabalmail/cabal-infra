import XCTest
@testable import Cabalmail

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
