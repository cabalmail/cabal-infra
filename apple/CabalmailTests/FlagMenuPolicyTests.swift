import XCTest
import CabalmailKit
@testable import Cabalmail

/// `FlagMenuPolicy`: which rows the reader's flag menu offers, and the
/// identity that makes macOS redraw it (#1329 — the AppKit menu is
/// materialized once per SwiftUI view identity and keeps its checkmarks
/// and titles thereafter).
final class FlagMenuPolicyTests: XCTestCase {
    private func entry(
        _ slot: String, _ label: String, enabled: Bool = true
    ) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: "blue", enabled: enabled)
    }

    // MARK: - Rows

    func testOffersEveryEnabledEntryInPaletteOrder() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-02", "Beta"), entry("cabal-flag-01", "Alpha")],
            taggedSlots: []
        )
        XCTAssertEqual(rows.map(\.slot), ["cabal-flag-02", "cabal-flag-01"])
        XCTAssertEqual(rows.map(\.label), ["Beta", "Alpha"])
        XCTAssertEqual(rows.map(\.isOn), [false, false])
    }

    func testATaggedSlotIsOn() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")],
            taggedSlots: ["cabal-flag-02"]
        )
        XCTAssertEqual(rows.map(\.isOn), [false, true])
    }

    /// A disabled entry is not offered, but a tag on it still needs its
    /// untag row — and keeps the entry's label.
    func testADisabledEntrysSurvivingTagKeepsItsLabel() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta", enabled: false)],
            taggedSlots: ["cabal-flag-02"]
        )
        XCTAssertEqual(rows.map(\.slot), ["cabal-flag-01", "cabal-flag-02"])
        XCTAssertEqual(rows.map(\.label), ["Alpha", "Beta"])
        XCTAssertEqual(rows.last?.isOn, true)
    }

    /// A deleted entry has no label left, so the slot id names the row.
    func testADeletedSlotsSurvivingTagIsLabelledByItsSlot() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha")],
            taggedSlots: ["cabal-flag-01", "cabal-flag-07"]
        )
        XCTAssertEqual(rows.map(\.slot), ["cabal-flag-01", "cabal-flag-07"])
        XCTAssertEqual(rows.last?.label, "cabal-flag-07")
    }

    func testAnUntaggedDisabledEntryIsNotOffered() {
        let rows = FlagMenuPolicy.rows(
            palette: [entry("cabal-flag-01", "Alpha", enabled: false)],
            taggedSlots: []
        )
        XCTAssertTrue(rows.isEmpty)
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
