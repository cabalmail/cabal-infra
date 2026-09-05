import SwiftUI
import XCTest
@testable import Cabalmail

/// #1453: the compose attachment-size warning drew in `.orange`, which the
/// light appearance resolves to `(255, 141, 40)`. Over the form's white row
/// that measures 2.31:1 — under the 4.5:1 WCAG AA floor for text, and under
/// even the 3:1 floor for non-text, on the one row in the form whose entire
/// job is to be noticed.
///
/// The tables below are the argument for a scheme-dependent colour rather
/// than a darker constant: the form's two row backgrounds pull in opposite
/// directions, and each candidate colour loses on one of them.
///
/// Every background and glyph value is a measured pixel from the report
/// (iPhone 17 and iPad Pro 11", iOS 26.5, both reading the same glyph), via
/// the same decoder `FolderNameTintTests` and `FolderIconTintTests` use.
final class AttachmentWarningTintTests: XCTestCase {

    /// WCAG 1.4.3: normal-size text needs 4.5:1 against its background. The
    /// warning is a `Label`, so its text sets the bar and the glyph rides
    /// along above the lower 3:1 non-text floor.
    private static let textFloor = 4.5

    /// The two backgrounds the compose form draws this row on.
    private static let lightRow = RGB.white
    private static let darkRow = RGB(44, 44, 46)

    // MARK: - The rule

    func testLightAppearanceDarkensTheOrange() {
        XCTAssertEqual(AttachmentWarningTint.tint(for: .light), .darkened)
    }

    func testDarkAppearanceKeepsThePlatformOrange() {
        XCTAssertEqual(AttachmentWarningTint.tint(for: .dark), .systemOrange)
    }

    // MARK: - What each branch measures

    /// The reported failure, pinned so the reasoning cannot drift away from
    /// the pixels it came from.
    func testTheShippedOrangeIsTheMeasuredFailure() {
        XCTAssertEqual(Self.lightRow.contrast(with: Self.systemOrangeLight), 2.31, accuracy: 0.01)
        XCTAssertLessThan(Self.lightRow.contrast(with: Self.systemOrangeLight), Self.textFloor)
    }

    /// The half that was already fine and is left alone: the dark
    /// appearance's `systemOrange` over the dark row.
    func testDarkAppearanceWasNeverUnderTheFloor() {
        XCTAssertEqual(Self.darkRow.contrast(with: Self.systemOrangeDark), 6.24, accuracy: 0.01)
        XCTAssertGreaterThan(Self.darkRow.contrast(with: Self.systemOrangeDark), Self.textFloor)
    }

    /// The fix, on the appearance that failed.
    func testDarkenedOrangeClearsTheFloorOnTheLightRow() {
        XCTAssertEqual(Self.lightRow.contrast(with: Self.darkened), 5.04, accuracy: 0.01)
        XCTAssertGreaterThan(Self.lightRow.contrast(with: Self.darkened), Self.textFloor)
    }

    /// The two branches end to end: for each appearance, what the rule
    /// picks, drawn on the row that appearance renders. This is the
    /// assertion the shipped code failed — the others measure colours, this
    /// one measures the rule.
    func testTheRuleClearsTheFloorInBothAppearances() {
        for appearance in [Appearance(scheme: .light, row: Self.lightRow),
                           Appearance(scheme: .dark, row: Self.darkRow)] {
            let tint = AttachmentWarningTint.tint(for: appearance.scheme)
            let drawn = Self.measuredPixel(for: tint, in: appearance.scheme)
            XCTAssertGreaterThan(
                appearance.row.contrast(with: drawn),
                Self.textFloor,
                "\(appearance.scheme) appearance"
            )
        }
    }

    // MARK: - Why the colour has to follow the scheme

    /// The claim the rule rests on: neither orange clears both rows, so
    /// there is no constant to pick. Shipping the darkened colour on *both*
    /// appearances would move the defect rather than fix it — it measures
    /// 2.77:1 on the dark row, which is worse than the 2.31:1 being fixed
    /// is on the light one.
    func testNeitherOrangeClearsBothRowBackgrounds() {
        for candidate in [Candidate(name: "the shipped systemOrange", color: Self.systemOrangeLight),
                          Candidate(name: "the darkened orange", color: Self.darkened)] {
            let losses = [Self.lightRow, Self.darkRow].filter {
                $0.contrast(with: candidate.color) < Self.textFloor
            }
            XCTAssertFalse(
                losses.isEmpty,
                "\(candidate.name) was expected to lose on one of the two rows and cleared both"
            )
        }
        XCTAssertEqual(Self.darkRow.contrast(with: Self.darkened), 2.77, accuracy: 0.01)
    }

    /// Why `darkeningFactor` is 0.65 and not something gentler: 0.70 lands
    /// at 4.45:1, still under the floor. A factor chosen to sit on the line
    /// would be a fix a rounding difference could undo — and this very
    /// assertion is the example, since rounding 178.5 up rather than to
    /// even is worth 0.02 of ratio all by itself.
    func testAGentlerDarkeningWouldStillBeUnderTheFloor() {
        let gentler = AttachmentWarningTint.systemOrangeLight.scaled(by: 0.70)
        XCTAssertEqual(
            Self.lightRow.contrast(with: RGB(gentler.red, gentler.green, gentler.blue)),
            4.45,
            accuracy: 0.01
        )
        XCTAssertLessThan(
            Self.lightRow.contrast(with: RGB(gentler.red, gentler.green, gentler.blue)),
            Self.textFloor
        )
    }

    /// Scaling every channel by one factor is what keeps the row reading as
    /// the same warning orange: the channel ratios are unchanged, so only
    /// the value moves.
    func testDarkeningHoldsTheHueThePlatformPicked() {
        let shipped = AttachmentWarningTint.systemOrangeLight
        let darkened = AttachmentWarningTint.darkenedOrange
        XCTAssertEqual(darkened, .init(red: 166, green: 92, blue: 26))
        XCTAssertEqual(
            darkened.red / darkened.green, shipped.red / shipped.green, accuracy: 0.02
        )
        XCTAssertEqual(
            darkened.green / darkened.blue, shipped.green / shipped.blue, accuracy: 0.02
        )
    }

    // MARK: - The instrument

    /// The instrument reproduces the report's controls from the same
    /// screenshots — the attachment filename at 20.87:1 and the `.secondary`
    /// byte-count caption at 4.42:1 — which is what says a 2.31:1 reading is
    /// the row and not the decoder.
    func testTheControlsFromTheSameScreenshotsStillRead() {
        XCTAssertEqual(Self.lightRow.contrast(with: RGB(1, 1, 1)), 20.87, accuracy: 0.01)
        XCTAssertEqual(Self.lightRow.contrast(with: RGB(120, 120, 120)), 4.42, accuracy: 0.01)
    }

    private static let systemOrangeLight = RGB(255, 141, 40)
    private static let systemOrangeDark = RGB(255, 146, 48)
    /// What each tint measures as, in the appearance it is picked for.
    /// `.systemOrange` is a dynamic colour, so it has one pixel per
    /// appearance and the scheme is part of the question.
    private static func measuredPixel(
        for tint: AttachmentWarningTint, in scheme: ColorScheme
    ) -> RGB {
        switch tint {
        case .systemOrange: scheme == .dark ? systemOrangeDark : systemOrangeLight
        case .darkened: darkened
        }
    }

    private static var darkened: RGB {
        let components = AttachmentWarningTint.darkenedOrange
        return RGB(components.red, components.green, components.blue)
    }
}

/// One appearance and the row background the compose form draws in it.
private struct Appearance {
    let scheme: ColorScheme
    let row: RGB
}

/// One colour the warning row could be drawn in.
private struct Candidate {
    let name: String
    let color: RGB
}
