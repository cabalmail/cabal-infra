import XCTest
import CabalmailKit
@testable import CabalmailUI

/// The default flag in Settings > Flags (unified-flags plan, decision 3):
/// which row is it, and what Make Default writes. The default is a
/// position, the first entry, so `FlagPaletteEntryBindings` answers
/// both from the palette's order.
@MainActor
final class FlagPaletteDefaultFlagTests: XCTestCase {
    private func entry(_ slot: String, _ label: String, color: String = "blue") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color)
    }

    private func preferences(_ palette: [FlagPaletteEntry]) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.flagPalette = palette
        return preferences
    }

    private func systemBindings(_ preferences: Preferences) -> FlagPaletteEntryBindings {
        FlagPaletteEntryBindings(preferences: preferences, slot: FlagPalette.systemSlot)
    }

    /// The default flag is the first entry, which for a palette nobody
    /// reordered is the built-in one, stored or not.
    func testTheFirstEntryIsTheDefault() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")])
        XCTAssertTrue(systemBindings(prefs).isDefault)
        XCTAssertFalse(systemBindings(prefs).canMakeDefault, "it already is")

        let alpha = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        XCTAssertFalse(alpha.isDefault)
        XCTAssertTrue(alpha.canMakeDefault)
    }

    /// Make Default is a move to the top, so the choice is the palette's
    /// order and nothing else: the built-in entry is stored where it lands,
    /// and the other flags keep their order.
    func testMakeDefaultMovesTheEntryToTheTop() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")])
        let beta = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }

        beta.makeDefault()

        XCTAssertEqual(
            prefs.flagPalette.map(\.slot),
            ["cabal-flag-02", FlagPalette.systemSlot, "cabal-flag-01"]
        )
        XCTAssertTrue(beta.isDefault)
        XCTAssertFalse(systemBindings(prefs).isDefault)
        XCTAssertEqual(FlagPalette.defaultEntry(in: prefs.flagPalette).slot, "cabal-flag-02")

        beta.makeDefault()
        XCTAssertEqual(localChanges, 1, "already the default: nothing to write")

        // And back: the built-in flag is made the default like any other.
        systemBindings(prefs).makeDefault()
        XCTAssertEqual(
            prefs.flagPalette.map(\.slot),
            [FlagPalette.systemSlot, "cabal-flag-02", "cabal-flag-01"]
        )
        XCTAssertTrue(systemBindings(prefs).isDefault)
    }

    /// A flag cannot be switched off. An entry a build from before that
    /// stored as `enabled: false` is the default when it is first, and can
    /// be made the default when it is not.
    func testAnEntryStoredAsSwitchedOffIsTheDefaultWhenFirstAndCanBeMadeIt() throws {
        let prefs = preferences(try XCTUnwrap(FlagPalette.decode(
            #"[{"color":"blue","enabled":false,"label":"Alpha","slot":"cabal-flag-01"},"#
                + #"{"color":"yellow","enabled":true,"label":"Flagged","slot":"\\Flagged"},"#
                + #"{"color":"blue","enabled":false,"label":"Beta","slot":"cabal-flag-02"}]"#
        )))
        let alpha = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        XCTAssertTrue(alpha.isDefault)
        XCTAssertFalse(systemBindings(prefs).isDefault)

        let beta = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        XCTAssertTrue(beta.canMakeDefault)
        beta.makeDefault()
        XCTAssertEqual(
            prefs.flagPalette.map(\.slot),
            ["cabal-flag-02", "cabal-flag-01", FlagPalette.systemSlot]
        )
        XCTAssertTrue(beta.isDefault)
    }

    /// Only an entry that is in the palette can be made the default.
    func testAnEntryThatIsGoneCannotBeMadeTheDefault() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")])
        let gone = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-09")
        XCTAssertFalse(gone.canMakeDefault)
        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }
        gone.makeDefault()
        XCTAssertEqual(localChanges, 0)
        XCTAssertEqual(prefs.flagPalette.map(\.slot), ["cabal-flag-01", "cabal-flag-02"])
    }
}
