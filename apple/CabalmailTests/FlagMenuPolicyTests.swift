import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlagMenuPolicy`: which rows a flag menu offers (the reader's, and the
/// list row's Flags submenu), and the identity that makes macOS redraw it
/// (#1329 — the AppKit menu is materialized once per SwiftUI view identity
/// and keeps its checkmarks and titles thereafter).
///
/// The rows are the effective palette, so the built-in flag's entry leads
/// every palette here that does not place it elsewhere.
final class FlagMenuPolicyTests: XCTestCase {
    private func entry(_ slot: String, _ label: String) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: "blue")
    }

    private let system = FlagPalette.systemSlot

    // MARK: - Rows

    func testOffersEveryEntryInPaletteOrder() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-02", "Beta"), entry("cabal-flag-01", "Alpha")],
            taggedSlots: []
        )
        XCTAssertEqual(rows.map(\.slot), [system, "cabal-flag-02", "cabal-flag-01"])
        XCTAssertEqual(rows.map(\.label), ["Flagged", "Beta", "Alpha"])
        XCTAssertEqual(rows.map(\.isOn), [false, false, false])
    }

    /// The built-in flag's entry is a row like the rest, where the palette
    /// puts it and under the name it has there.
    func testTheBuiltInFlagIsARowAtItsPalettePosition() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha"), entry(system, "Urgent")],
            taggedSlots: [system]
        )
        XCTAssertEqual(rows.map(\.slot), ["cabal-flag-01", system])
        XCTAssertEqual(rows.map(\.label), ["Alpha", "Urgent"])
        XCTAssertEqual(rows.map(\.isOn), [false, true])
    }

    func testATaggedSlotIsOn() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")],
            taggedSlots: ["cabal-flag-02"]
        )
        XCTAssertEqual(rows.map(\.isOn), [false, false, true])
    }

    /// A flag cannot be switched off, so an entry a build from before that
    /// stored as `enabled: false` is a row like the rest, to set as well as
    /// to clear, in its palette position.
    func testAnEntryStoredAsSwitchedOffIsOfferedLikeAnyOther() throws {
        let palette = try XCTUnwrap(FlagPalette.decode(
            #"[{"color":"blue","enabled":false,"label":"Beta","slot":"cabal-flag-02"},"#
                + #"{"color":"blue","enabled":true,"label":"Alpha","slot":"cabal-flag-01"}]"#
        ))
        let untagged = FlagMenuPolicy.rows(palette: palette, taggedSlots: [])
        XCTAssertEqual(untagged.map(\.slot), [system, "cabal-flag-02", "cabal-flag-01"])
        XCTAssertEqual(untagged.map(\.label), ["Flagged", "Beta", "Alpha"])
        XCTAssertEqual(untagged.map(\.isOn), [false, false, false])

        let tagged = FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-02"])
        XCTAssertEqual(tagged.map(\.isOn), [false, true, false])
    }

    /// A deleted entry has no label left, so the slot id names the row.
    func testADeletedSlotsSurvivingTagIsLabelledByItsSlot() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha")],
            taggedSlots: ["cabal-flag-01", "cabal-flag-07"]
        )
        XCTAssertEqual(rows.map(\.slot), [system, "cabal-flag-01", "cabal-flag-07"])
        XCTAssertEqual(rows.last?.label, "cabal-flag-07")
    }

    /// The control the menu hangs from toggles the default flag itself, so
    /// a menu that could only repeat that one row is no menu: the control
    /// stays the plain button it is for a palette nobody has added to,
    /// flagged message or not.
    func testTheDefaultFlagAloneIsNoMenu() {
        XCTAssertTrue(FlagMenuPolicy.rows(palette: [], taggedSlots: []).isEmpty)
        XCTAssertTrue(FlagMenuPolicy.rows(palette: [], taggedSlots: [system]).isEmpty)
        XCTAssertTrue(
            FlagMenuPolicy.rows(palette: [entry(system, "Urgent")], taggedSlots: []).isEmpty,
            "renamed, it is still the only flag"
        )
        XCTAssertTrue(
            FlagMenuPolicy.rows(palette: [entry(system, "Urgent")], taggedSlots: [system]).isEmpty,
            "set on the message, the button's own press clears it"
        )
    }

    /// A second flag makes it a menu, whichever of the two is the default.
    func testASecondFlagIsAMenu() {
        XCTAssertEqual(
            FlagMenuPolicy.rows(palette: [entry("cabal-flag-01", "Alpha")], taggedSlots: []).map(\.slot),
            [system, "cabal-flag-01"]
        )
        XCTAssertEqual(
            FlagMenuPolicy.rows(
                palette: [entry("cabal-flag-01", "Alpha"), entry(system, "Flagged")], taggedSlots: []
            ).map(\.slot),
            ["cabal-flag-01", system]
        )
    }

    /// A single row that is not the default flag is still a menu: the
    /// control's own press would not reach it.
    func testAStrayTagBesideTheDefaultFlagIsOffered() {
        let rows = FlagMenuPolicy.rows(palette: [], taggedSlots: ["cabal-flag-07"])
        XCTAssertEqual(rows.map(\.slot), [system, "cabal-flag-07"])
    }

    // MARK: - Identity

    /// The reported defect: applying a tag from the menu must replace the
    /// menu, or the row that was just checked keeps drawing unchecked.
    func testIdentityChangesWhenARowIsCheckedOrUnchecked() {
        let palette = [entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")]
        let before = FlagMenuPolicy.identity(
            FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-01"])
        )
        let after = FlagMenuPolicy.identity(
            FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-01", "cabal-flag-02"])
        )
        XCTAssertNotEqual(before, after)
    }

    /// Measured alongside the checkmark: a frozen menu keeps its row
    /// *titles* too, so a rename has to replace the menu as well.
    func testIdentityChangesWhenARowIsRelabelled() {
        let tagged: Set<String> = ["cabal-flag-01"]
        let before = FlagMenuPolicy.identity(
            FlagMenuPolicy.rows(palette: [entry("cabal-flag-01", "Alpha")], taggedSlots: tagged)
        )
        let after = FlagMenuPolicy.identity(
            FlagMenuPolicy.rows(palette: [entry("cabal-flag-01", "Alpha 2")], taggedSlots: tagged)
        )
        XCTAssertNotEqual(before, after)
    }

    /// Palette array order is display order, so a reorder is a visible
    /// change even though the same rows are present.
    func testIdentityChangesWhenRowsAreReordered() {
        let alpha = entry("cabal-flag-01", "Alpha")
        let beta = entry("cabal-flag-02", "Beta")
        XCTAssertNotEqual(
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(palette: [alpha, beta], taggedSlots: [])),
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(palette: [beta, alpha], taggedSlots: []))
        )
    }

    /// The other half of the contract: an identity that churned on every
    /// body pass would rebuild the menu constantly, so equal content must
    /// give an equal key.
    func testIdentityIsStableForUnchangedContent() {
        let palette = [entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")]
        XCTAssertEqual(
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-02"])),
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(palette: palette, taggedSlots: ["cabal-flag-02"]))
        )
    }

    /// A label may contain the separator-ish characters a naive join would
    /// collide on; two different palettes must not share a key.
    func testLabelsContainingPipesDoNotCollide() {
        let tagged: Set<String> = []
        XCTAssertNotEqual(
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(
                palette: [entry("cabal-flag-01", "a|b|0"), entry("cabal-flag-02", "c")],
                taggedSlots: tagged
            )),
            FlagMenuPolicy.identity(FlagMenuPolicy.rows(
                palette: [entry("cabal-flag-01", "a"), entry("cabal-flag-02", "b|0|c")],
                taggedSlots: tagged
            ))
        )
    }
}
