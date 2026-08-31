import XCTest
@testable import Cabalmail

/// #1318: a selected folder row's icon was pinned to `Color.white` on the
/// touch platforms, on the premise that "iPadOS sidebar selection paints the
/// row in the accent color". iPadOS 26.5 paints an unemphasized light grey,
/// and behind one of the two rows it renders for the selected path it paints
/// nothing at all — so the icon measured 1.52:1 on the first row and 1.00:1
/// (invisible) on the second.
///
/// The rule the fix rests on is that *no* pinned colour survives every fill
/// the platforms draw behind a selected row, so the row's own foreground is
/// the only safe answer. The tables below are that argument: each candidate
/// colour is measured against each fill, and each candidate loses somewhere.
///
/// Every background is a measured pixel from the iPadOS 26.5 simulator (the
/// report and its verification pass agree to the digit); the two glyph
/// colours are the asset catalog's own components, pinned against the
/// catalog by `testBrandAccentMatchesTheAssetCatalog`.
final class FolderIconTintTests: XCTestCase {

    /// WCAG 1.4.11: a non-text UI component needs 3:1 against what is
    /// adjacent to it. An icon is not text, so this is the floor it has to
    /// clear — a lower bar than the 4.5:1 `FolderNameTint` works to, and the
    /// shipped rule missed it anyway.
    private static let nonTextFloor = 3.0

    // MARK: - The rule

    /// The half that failed. A selected row takes no pinned colour at all:
    /// whatever the list drew behind it, the row's own hierarchical
    /// foreground is already legible against it.
    func testSelectedRowInheritsRatherThanPinningAColour() {
        XCTAssertEqual(FolderIconTint.tint(isSelected: true), .inherited)
    }

    /// The half that was right and stays: an unselected row carries the
    /// brand accent, which is the whole reason the icons are tinted.
    func testUnselectedRowKeepsTheBrandAccent() {
        XCTAssertEqual(FolderIconTint.tint(isSelected: false), .accent)
    }

    // MARK: - Why no pinned colour would have done

    /// The three fills a selected folder row is drawn on. The first two are
    /// measured, in the same screenshots, on the two rows the sidebar
    /// renders for the selected path; the third is the emphasized selection
    /// the pinned white was written for, which is the user's accent choice
    /// and so is only representable by its default.
    private static let selectedRowFills = [
        Fill(name: "iPadOS unemphasized selection", color: RGB(209, 209, 214)),
        Fill(name: "no fill at all (the duplicate row for the selected path)", color: .white),
        Fill(name: "emphasized selection, macOS default accent", color: RGB(0, 122, 255))
    ]

    /// The two colours that could have been pinned instead: the white that
    /// shipped, and the brand accent macOS ships. Every one of them is
    /// below the floor on at least one of the three fills, which is the
    /// argument for `.inherited` rather than a third guess.
    func testEveryPinnedCandidateIsUnderTheFloorOnSomeSelectedRowFill() {
        for candidate in [Candidate(name: "pinned white", color: .white),
                          Candidate(name: "pinned brand accent", color: Self.brandAccentLight)] {
            let failures = Self.selectedRowFills.filter {
                $0.color.contrast(with: candidate.color) < Self.nonTextFloor
            }
            XCTAssertFalse(
                failures.isEmpty,
                "\(candidate.name) was expected to lose on some fill, and cleared all of "
                    + Self.selectedRowFills.map(\.name).joined(separator: ", ")
            )
        }
    }

    /// The reported numbers, pinned so the reasoning above cannot drift away
    /// from the pixels it came from.
    func testTheShippedWhiteIsTheMeasuredFailure() {
        XCTAssertEqual(RGB(209, 209, 214).contrast(with: .white), 1.52, accuracy: 0.01)
        XCTAssertEqual(RGB.white.contrast(with: .white), 1.00, accuracy: 0.01)
    }

    /// And the numbers that rule out the obvious replacement. Pinning the
    /// accent everywhere — what macOS already does — is comfortable on both
    /// of the fills iPadOS was measured drawing, which is exactly why the
    /// emphasized case is the one worth writing down.
    func testPinningTheAccentOnlyLosesOnTheEmphasizedFill() {
        let accent = Self.brandAccentLight
        XCTAssertEqual(RGB(209, 209, 214).contrast(with: accent), 4.68, accuracy: 0.01)
        XCTAssertEqual(RGB.white.contrast(with: accent), 7.12, accuracy: 0.01)
        XCTAssertLessThan(RGB(0, 122, 255).contrast(with: accent), Self.nonTextFloor)
    }

    /// The control the report measured in the same screenshots: an
    /// unselected row's accent icon on the sidebar's white. It is what
    /// proves the icon is drawn at all, and the case this fix leaves alone.
    func testUnselectedRowIsAndStaysWellClearOfTheFloor() {
        XCTAssertGreaterThan(
            RGB.white.contrast(with: Self.brandAccentLight), Self.nonTextFloor
        )
    }

    // MARK: - The instrument

    /// The brand accent above is a copy of the asset catalog's light
    /// variant, and a copy goes stale silently — a rebrand would leave every
    /// ratio here describing a colour the app no longer draws. Read the
    /// catalog and compare.
    func testBrandAccentMatchesTheAssetCatalog() {
        for target in ["Cabalmail", "CabalmailMac"] {
            let url = Self.appleDirectory
                .appendingPathComponent("\(target)/Assets.xcassets/AccentColor.colorset/Contents.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let colors = json["colors"] as? [[String: Any]]
            else {
                return XCTFail("could not read \(target)'s AccentColor.colorset")
            }
            // The universal entry, i.e. the one with no dark appearance on it.
            guard let universal = colors.first(where: { $0["appearances"] == nil }),
                  let components = (universal["color"] as? [String: Any])?["components"] as? [String: String]
            else {
                return XCTFail("\(target)'s AccentColor has no appearance-free entry")
            }
            XCTAssertEqual(Self.channel(components["red"]), Self.brandAccentLight.red, "\(target) red")
            XCTAssertEqual(Self.channel(components["green"]), Self.brandAccentLight.green, "\(target) green")
            XCTAssertEqual(Self.channel(components["blue"]), Self.brandAccentLight.blue, "\(target) blue")
        }
    }

    /// The forest green the folder icons are tinted with, light appearance.
    private static let brandAccentLight = RGB(43, 99, 58)

    /// `apple/`, two levels up from this file — the same trick the app's
    /// source-scanning invariants use, since a unit test bundle has no
    /// pointer back to the checkout.
    private static var appleDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func channel(_ hex: String?) -> Double {
        guard let hex, let value = UInt8(hex.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
            return -1
        }
        return Double(value)
    }
}

/// One fill a selected folder row can be drawn on.
private struct Fill {
    let name: String
    let color: RGB
}

/// One colour the icon could have been pinned to instead of inheriting.
private struct Candidate {
    let name: String
    let color: RGB
}
