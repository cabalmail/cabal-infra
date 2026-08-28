import XCTest
@testable import Cabalmail

/// #1297: colouring folder names by unread state took the sidebar from
/// ~14:1 to 1.52:1 on the selected row and 4.00:1 on caught-up rows.
///
/// Two halves, tested separately because they failed for different reasons:
/// the selected row failed because the rule pinned a colour the selection
/// fill doesn't cooperate with, and the caught-up rows failed because
/// `.secondary`'s alpha is picked by the OS rather than for contrast.
///
/// Every background and every resolved alpha below is a measured pixel, not
/// a model — from the iPadOS 26.5 simulator and a macOS 26.6 build here, and
/// from the filed report for macOS 27.
final class FolderNameTintTests: XCTestCase {

    // MARK: - The rule

    /// The selected row takes no pinned colour, unread or not. This is the
    /// half that read 1.52:1 (white on iPadOS's unemphasized grey fill) and
    /// 1.00:1 (white on white, in the "All folders" section's second row for
    /// the selected path, which draws no fill at all).
    func testSelectedRowInheritsWhateverTheFillLeftBehind() {
        XCTAssertEqual(FolderNameTint.tint(hasUnread: true, isSelected: true), .inherited)
        XCTAssertEqual(FolderNameTint.tint(hasUnread: false, isSelected: true), .inherited)
    }

    /// Unselected rows still carry the unread signal #1294 added — the fix
    /// is about how far the caught-up state dims, not about dropping it.
    func testUnselectedRowsStillSignalUnreadState() {
        XCTAssertEqual(FolderNameTint.tint(hasUnread: true, isSelected: false), .unread)
        XCTAssertEqual(FolderNameTint.tint(hasUnread: false, isSelected: false), .caughtUp)
    }

    // MARK: - The dimming, over the backgrounds it was measured against

    /// Backgrounds that composite an opacity source-over: the touch
    /// platforms' opaque sidebar, plus the extreme each appearance cannot
    /// go past. The label colour inverts with the appearance, so the dark
    /// cases have to be checked from the other side rather than assumed.
    private static let sourceOverCases = [
        DimCase(name: "iPadOS 26.5 sidebar, light", background: RGB(255, 255, 255), label: .black),
        DimCase(name: "dark appearance, sidebar", background: RGB(50, 50, 50), label: .white),
        DimCase(name: "dark appearance, worst case", background: .black, label: .white)
    ]

    /// Where the opacity lands as asked, `dimmedOpacity` clears AA outright.
    func testCaughtUpNameClearsAAWhereTheOpacityLandsAsAsked() {
        for dimCase in Self.sourceOverCases {
            let glyph = dimCase.background.composited(
                with: dimCase.label, alpha: FolderNameTint.dimmedOpacity
            )
            let ratio = dimCase.background.contrast(with: glyph)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(dimCase.name): \(Self.format(ratio)):1")
        }
    }

    /// macOS discounts it, so the same constant has to clear AA at
    /// `dimmedOpacity * macOSVibrancyDiscount` over the sidebar material of
    /// both OS generations. This is the assertion that fails at 0.6.
    func testCaughtUpNameClearsAAThroughTheMacOSVibrancyDiscount() {
        let effective = FolderNameTint.dimmedOpacity * FolderNameTint.macOSVibrancyDiscount
        for dimCase in Self.macOSSidebarMaterials {
            let glyph = dimCase.background.composited(with: dimCase.label, alpha: effective)
            let ratio = dimCase.background.contrast(with: glyph)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(dimCase.name): \(Self.format(ratio)):1")
        }
    }

    /// The candidate this fix was nearly shipped with. Recorded as a test
    /// rather than a comment because the failure is invisible from the
    /// source: 0.6 clears AA everywhere the opacity lands as asked, and only
    /// the macOS discount puts it under — at 4.04:1 measured, below the
    /// 5.29:1 `.secondary` was already achieving on macOS 26.
    func testTheDiscountIsWhatRulesOutTheObviousSmallerFraction() {
        let effective = 0.6 * FolderNameTint.macOSVibrancyDiscount
        let macOS26 = RGB(236, 240, 243)
        XCTAssertLessThan(macOS26.contrast(with: macOS26.composited(with: .black, alpha: effective)), 4.5)
        // …while the same 0.6 looks perfectly safe on the touch platforms.
        XCTAssertGreaterThan(RGB.white.contrast(with: RGB.white.composited(with: .black, alpha: 0.6)), 4.5)
    }

    /// The negative control, and the reason `dimmedOpacity` is a number we
    /// pick rather than `.secondary`: the alphas the OS actually resolved
    /// `.secondary` to are what put the reported rows under AA. 50% black is
    /// iPadOS's measured `(127, 127, 127)` on white; 46% is what macOS 27's
    /// reported `(132, 128, 124)` implies over its sidebar material.
    func testTheResolvedSecondaryAlphasAreTheOnesThatFailed() {
        XCTAssertLessThan(RGB.white.contrast(with: RGB.white.composited(with: .black, alpha: 0.5)), 4.5)

        let macOS27 = RGB(230, 224, 217)
        XCTAssertLessThan(macOS27.contrast(with: macOS27.composited(with: .black, alpha: 0.46)), 4.5)
    }

    private static let macOSSidebarMaterials = [
        DimCase(name: "macOS 26.6 sidebar material", background: RGB(236, 240, 243), label: .black),
        DimCase(name: "macOS 27.0 sidebar material", background: RGB(230, 224, 217), label: .black)
    ]

    private static func format(_ ratio: Double) -> String {
        String(format: "%.2f", ratio)
    }

    // MARK: - The instrument

    /// The contrast arithmetic is only worth asserting against if it can
    /// fail, so pin it on the two ratios WCAG fixes by definition plus the
    /// two glyph/background pairs actually sampled off the reported screens.
    func testContrastHelperIsNotVacuous() {
        XCTAssertEqual(RGB.white.contrast(with: .black), 21, accuracy: 0.01)
        XCTAssertEqual(RGB.white.contrast(with: .white), 1, accuracy: 0.01)
        // The measured iPadOS caught-up row: (127,127,127) on white.
        XCTAssertEqual(RGB.white.contrast(with: RGB(127, 127, 127)), 4.00, accuracy: 0.01)
        // The measured iPadOS selected row: white on the unemphasized fill.
        XCTAssertEqual(RGB(209, 209, 214).contrast(with: .white), 1.52, accuracy: 0.01)
    }

    /// Compositing has to agree with the pixels the live arms produced, or
    /// the contrast assertions above are checking a fiction. Both are the
    /// post-fix glyph colours read off the screenshots.
    func testCompositingReproducesTheMeasuredGlyphs() {
        let iPad = RGB.white.composited(with: .black, alpha: FolderNameTint.dimmedOpacity)
        XCTAssertEqual(iPad.red, 76.5, accuracy: 0.5, "iPadOS measured (76, 76, 76)")

        let macOS = RGB(236, 240, 243).composited(
            with: .black,
            alpha: FolderNameTint.dimmedOpacity * FolderNameTint.macOSVibrancyDiscount
        )
        XCTAssertEqual(macOS.red, 96, accuracy: 1.5, "macOS 26.6 measured (96, 98, 99)")
    }
}

/// One surface a caught-up folder name is drawn on, and the label colour the
/// appearance gives it there.
private struct DimCase {
    let name: String
    let background: RGB
    let label: RGB
}

/// WCAG relative luminance and contrast over 8-bit sRGB, plus source-over
/// compositing so an opacity can be turned into the pixel it produces.
/// Test-only: the app never computes a contrast ratio, it just has to clear
/// one.
private struct RGB {
    static let black = RGB(0, 0, 0)
    static let white = RGB(255, 255, 255)

    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// This colour with `other` laid over it at `alpha`, which is what a
    /// `Color.primary.opacity(_:)` label does to the pixel beneath it.
    func composited(with other: RGB, alpha: Double) -> RGB {
        RGB(
            red + (other.red - red) * alpha,
            green + (other.green - green) * alpha,
            blue + (other.blue - blue) * alpha
        )
    }

    var relativeLuminance: Double {
        func channel(_ value: Double) -> Double {
            let unit = value / 255
            return unit <= 0.03928 ? unit / 12.92 : pow((unit + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(with other: RGB) -> Double {
        let lhs = relativeLuminance
        let rhs = other.relativeLuminance
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }
}
