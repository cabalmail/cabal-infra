import XCTest
@testable import Cabalmail

// Regression coverage for #931: the launch resume banner ("Pick up where you
// left off in Archive?") is an overlay on the whole section layout, so at
// regular width it drew across the navigation bar's trailing items and hid New
// Message, Addresses and the search field for the banner's whole ~60s life.
// The same placement carries every other banner (the "Created <address>"
// confirmation was reported behaving identically), so the inset is the fix's
// one number — pinned here against the frames the report measured.
final class StatusBannerPlacementTests: XCTestCase {

    /// Where the banner overlay's own top edge sits: the window's top safe
    /// area. Derived from the report — the capsule's top landed at y≈22pt on
    /// the iPad Pro 11" with the 6pt default inset applied.
    private let overlayOrigin: CGFloat = 16

    /// The navigation bar's band on the same device: the trailing toolbar
    /// items measured {y 36, height 36}.
    private let toolbarBandBottom: CGFloat = 72

    func testRegularWidthBannersClearTheToolbarBand() {
        let bannerTop = overlayOrigin + StatusBannerPlacement.topInset(isRegularWidth: true)
        XCTAssertGreaterThan(
            bannerTop, toolbarBandBottom,
            "a banner starting inside the bar's band covers New Message, Addresses and search"
        )
    }

    /// #958's iPhone 16 Pro frames: the overlay's origin is the top safe area,
    /// which is also where the navigation bar starts ({{0, 62}, {402, 54}}).
    private let compactOverlayOrigin: CGFloat = 62
    private let compactNavigationBarBottom: CGFloat = 116

    // Regression coverage for #958: the same overlay hid the compact-width
    // navigation bar's centre title slot, which is not empty — it carries the
    // folder name you just landed in. The banner has to clear the bar at both
    // widths, so the compact inset gets pinned against the iPhone frames the
    // same way the regular-width one is pinned against the iPad's.
    func testCompactWidthBannersClearTheNavigationBar() {
        let bannerTop = compactOverlayOrigin + StatusBannerPlacement.topInset(isRegularWidth: false)
        XCTAssertGreaterThan(
            bannerTop, compactNavigationBarBottom,
            "a banner starting inside the bar's band covers the folder-name title"
        )
    }

    func testPlatformsWithoutANavigationBarInTheBandKeepThePlainGap() {
        // macOS and visionOS bypass `topInset(isRegularWidth:)` entirely and
        // read this constant, so nothing above may quietly push their banners
        // down past the window chrome they already sit below.
        XCTAssertEqual(StatusBannerPlacement.defaultTopInset, 6)
    }
}
