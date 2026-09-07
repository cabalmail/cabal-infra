import SwiftUI
import XCTest
@testable import Cabalmail

/// #1453 and #1456: the app's warning surfaces drew in `.orange`, which the
/// light appearance resolves to `(255, 141, 40)`. On a light row that
/// measures 2.31:1 — under the 4.5:1 WCAG AA floor for text, and under even
/// the 3:1 floor for non-text.
///
/// #1453 fixed one of them, the compose attachment-size warning, and said in
/// its own issue that the sweep was deliberately not done. #1456 did the
/// sweep and measured five more failures: two message-row indicators, the
/// reader's authentication warning sentence and its verdict chips, and the
/// `Suspended` caption under a suspended address. The two watch sites draw
/// on black (7.12:1 and 9.41:1) and were the report's own prediction, which
/// is what says the number tracks the background and not the colour name.
///
/// Two halves are tested here, because the defect has two halves. The rule
/// is a policy, which is directly testable. But the rule already existed —
/// `AttachmentWarningTint` had shipped with it — and seven call sites simply
/// kept their own `.orange`, so the second half is a source-level invariant:
/// no view may answer this question on its own.
///
/// Every background and glyph value below is a measured pixel from the two
/// reports (iPhone 17, iPad Pro 11" and an Apple Watch Series 11 at iOS/
/// watchOS 26.5), via the same decoder `FolderNameTintTests` and
/// `FolderIconTintTests` use.
final class WarningTintTests: XCTestCase {

    /// WCAG 1.4.3: normal-size text needs 4.5:1 against its background. Three
    /// of the failing sites are `.caption`/`.caption2` text, so the text
    /// floor sets the bar and the two icon-only indicators ride along above
    /// the lower 3:1 non-text floor.
    private static let textFloor = 4.5

    /// The backgrounds the tint is drawn on.
    private static let lightRow = RGB.white
    private static let darkRow = RGB(44, 44, 46)

    /// The iPad Addresses **inspector** dims the whole window, its own card
    /// included, and #1456 measured that taking the shipped orange from
    /// 2.31:1 on the iPhone's undimmed card to 2.08:1 there — the tint keeps
    /// ~0.92 of its ratio. A colour that lands exactly on the floor
    /// undimmed is therefore under it on that surface, so the worst light
    /// background has to clear the floor by the reciprocal.
    private static let inspectorDimAllowance = 1.09

    // MARK: - The rule

    func testLightAppearanceDarkensTheOrange() {
        XCTAssertEqual(WarningTint.tint(for: .light), .darkened)
    }

    func testDarkAppearanceKeepsThePlatformOrange() {
        XCTAssertEqual(WarningTint.tint(for: .dark), .systemOrange)
    }

    // MARK: - What each branch measures

    /// The reported failure, pinned so the reasoning cannot drift away from
    /// the pixels it came from. The same 2.31:1 was read on the compose row
    /// (#1453), on both message-row indicators, on the reader's warning
    /// sentence and on the `Suspended` caption (#1456) — one colour on one
    /// white background, five times.
    func testTheShippedOrangeIsTheMeasuredFailure() {
        XCTAssertEqual(Self.lightRow.contrast(with: Self.systemOrangeLight), 2.31, accuracy: 0.01)
        XCTAssertLessThan(Self.lightRow.contrast(with: Self.systemOrangeLight), Self.textFloor)
    }

    /// The half that was already fine and is left alone: the dark
    /// appearance's `systemOrange` over the compose form's dark row.
    func testDarkAppearanceWasNeverUnderTheFloor() {
        XCTAssertEqual(Self.darkRow.contrast(with: Self.systemOrangeDark), 6.24, accuracy: 0.01)
        XCTAssertGreaterThan(Self.darkRow.contrast(with: Self.systemOrangeDark), Self.textFloor)
    }

    /// The fix, on the appearance that failed.
    func testDarkenedOrangeClearsTheFloorOnTheLightRow() {
        XCTAssertEqual(Self.lightRow.contrast(with: Self.darkened), 6.53, accuracy: 0.01)
        XCTAssertGreaterThan(Self.lightRow.contrast(with: Self.darkened), Self.textFloor)
    }

    /// The two branches end to end: for each appearance, what the rule
    /// picks, drawn on the row that appearance renders. This is the
    /// assertion the shipped code failed — the others measure colours, this
    /// one measures the rule.
    func testTheRuleClearsTheFloorInBothAppearances() {
        for appearance in [Appearance(scheme: .light, row: Self.lightRow),
                           Appearance(scheme: .dark, row: Self.darkRow)] {
            let tint = WarningTint.tint(for: appearance.scheme)
            let drawn = Self.measuredPixel(for: tint, in: appearance.scheme)
            XCTAssertGreaterThan(
                appearance.row.contrast(with: drawn),
                Self.textFloor,
                "\(appearance.scheme) appearance"
            )
        }
    }

    // MARK: - The chip, which sets the constant

    /// The instrument, checked against the pixel #1456 read off the chip:
    /// the capsule is the chip's own colour at `chipWashOpacity` over the
    /// reader's white background, and that composites to exactly the
    /// (255, 241, 229) measured on all three chips (SPF, DKIM, DMARC).
    func testTheChipWashModelReproducesTheMeasuredCapsule() {
        let wash = Self.lightRow.composited(with: Self.systemOrangeLight, alpha: WarningTint.chipWashOpacity)
        XCTAssertEqual(wash.red, 255, accuracy: 0.5)
        XCTAssertEqual(wash.green, 241, accuracy: 0.5)
        XCTAssertEqual(wash.blue, 229, accuracy: 0.5)
        XCTAssertEqual(wash.contrast(with: Self.systemOrangeLight), 2.09, accuracy: 0.01)
    }

    /// The chip is the worst light surface this tint draws on, because it is
    /// the only one whose background is *derived from the tint*: darkening
    /// the label lightens the capsule under it and hands part of the gain
    /// straight back. Every other site draws on a row the tint has no say
    /// in, which is why choosing the constant against white is not enough.
    func testTheChipIsTheWorstLightSurfaceAndTheTintStillClearsIt() {
        let wash = Self.lightRow.composited(with: Self.darkened, alpha: WarningTint.chipWashOpacity)
        XCTAssertEqual(wash.contrast(with: Self.darkened), 5.47, accuracy: 0.01)
        XCTAssertLessThan(
            wash.contrast(with: Self.darkened),
            Self.lightRow.contrast(with: Self.darkened),
            "the chip has to be the harder of the two or this test is measuring nothing"
        )
        XCTAssertGreaterThan(
            wash.contrast(with: Self.darkened),
            Self.textFloor * Self.inspectorDimAllowance
        )
    }

    // MARK: - Why the constant is what it is

    /// The claim the rule rests on: neither orange clears both rows, so
    /// there is no constant to pick. Shipping the darkened colour on *both*
    /// appearances would move the defect rather than fix it — it measures
    /// 2.13:1 on the dark row, which is worse than the 2.31:1 being fixed is
    /// on the light one.
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
        XCTAssertEqual(Self.darkRow.contrast(with: Self.darkened), 2.13, accuracy: 0.01)
    }

    /// Why `darkeningFactor` moved from the 0.65 #1453 shipped to 0.55: both
    /// clear the floor on white, and the gentler two do not survive the chip
    /// or the inspector.
    ///
    /// | factor | on white | on its own wash | verdict |
    /// | --- | --- | --- | --- |
    /// | 0.65 (#1453) | 5.04 | 4.30 | fails the chip outright |
    /// | 0.60 | 5.73 | 4.84 | clears the chip, under it once dimmed |
    /// | 0.55 (shipped) | 6.53 | 5.47 | clears both with headroom |
    ///
    /// The middle row is the reason the margin is not a matter of taste: a
    /// constant chosen against the chip alone would have been 0.60, and the
    /// iPad inspector's dimming is measured, not hypothetical.
    func testTheGentlerCandidatesLoseOnTheChip() {
        for candidate in [Candidate(name: "0.65, the factor #1453 shipped", color: Self.scaled(0.65)),
                          Candidate(name: "0.60", color: Self.scaled(0.60))] {
            let wash = Self.lightRow.composited(with: candidate.color, alpha: WarningTint.chipWashOpacity)
            XCTAssertGreaterThan(
                Self.lightRow.contrast(with: candidate.color),
                Self.textFloor,
                "\(candidate.name) was expected to look fine on white"
            )
            XCTAssertLessThan(
                wash.contrast(with: candidate.color),
                Self.textFloor * Self.inspectorDimAllowance,
                "\(candidate.name) was expected to lose on the chip"
            )
        }
        XCTAssertEqual(
            Self.lightRow.composited(with: Self.scaled(0.65), alpha: WarningTint.chipWashOpacity)
                .contrast(with: Self.scaled(0.65)),
            4.30,
            accuracy: 0.01
        )
    }

    /// Scaling every channel by one factor is what keeps a warning reading as
    /// the same warning orange: the channel ratios are unchanged, so only
    /// the value moves.
    func testDarkeningHoldsTheHueThePlatformPicked() {
        let shipped = WarningTint.systemOrangeLight
        let darkened = WarningTint.darkenedOrange
        XCTAssertEqual(darkened, .init(red: 140, green: 78, blue: 22))
        XCTAssertEqual(
            darkened.red / darkened.green, shipped.red / shipped.green, accuracy: 0.02
        )
        XCTAssertEqual(
            darkened.green / darkened.blue, shipped.green / shipped.blue, accuracy: 0.05
        )
    }

    // MARK: - The instrument

    /// The instrument reproduces the controls from the same screenshots —
    /// the attachment filename at 20.87:1, the `.secondary` byte-count
    /// caption at 4.42:1, and #1456's watch arm, where the same code path on
    /// black reads 7.12:1 — which is what says a 2.31:1 reading is the row
    /// and not the decoder.
    func testTheControlsFromTheSameScreenshotsStillRead() {
        XCTAssertEqual(Self.lightRow.contrast(with: RGB(1, 1, 1)), 20.87, accuracy: 0.01)
        XCTAssertEqual(Self.lightRow.contrast(with: RGB(120, 120, 120)), 4.42, accuracy: 0.01)
        XCTAssertEqual(RGB(34, 34, 35).contrast(with: Self.systemOrangeDark), 7.12, accuracy: 0.01)
    }

    private static let systemOrangeLight = RGB(255, 141, 40)
    private static let systemOrangeDark = RGB(255, 146, 48)

    /// What each tint measures as, in the appearance it is picked for.
    /// `.systemOrange` is a dynamic colour, so it has one pixel per
    /// appearance and the scheme is part of the question.
    private static func measuredPixel(
        for tint: WarningTint, in scheme: ColorScheme
    ) -> RGB {
        switch tint {
        case .systemOrange: scheme == .dark ? systemOrangeDark : systemOrangeLight
        case .darkened: darkened
        }
    }

    private static func scaled(_ factor: Double) -> RGB {
        let components = WarningTint.systemOrangeLight.scaled(by: factor)
        return RGB(components.red, components.green, components.blue)
    }

    private static var darkened: RGB {
        let components = WarningTint.darkenedOrange
        return RGB(components.red, components.green, components.blue)
    }
}

/// One appearance and the row background drawn in it.
private struct Appearance {
    let scheme: ColorScheme
    let row: RGB
}

/// One colour a warning could be drawn in.
private struct Candidate {
    let name: String
    let color: RGB
}
