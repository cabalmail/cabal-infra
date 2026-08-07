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

    func testCompactWidthKeepsTheBannerInTheTitleSlot() {
        XCTAssertEqual(
            StatusBannerPlacement.topInset(isRegularWidth: false),
            StatusBannerPlacement.defaultTopInset,
            "compact width has an empty centre title slot — the banner belongs in it"
        )
    }

    func testTheRegularWidthInsetIsTheLargerOfTheTwo() {
        XCTAssertGreaterThan(
            StatusBannerPlacement.topInset(isRegularWidth: true),
            StatusBannerPlacement.topInset(isRegularWidth: false)
        )
    }
}
