import XCTest
@testable import CabalmailKit

/// A palette as a build from before the Enabled switch left custom flags
/// stored it: `enabled` on every entry, false on a flag that was switched
/// off. Such rows stay on the server until a newer build next pushes the
/// user's settings, so the key has to be skipped on the way in and left
/// out on the way back (`docs/2.x/flag-palette-enabled-removal.md`).
final class FlagPaletteStoredEnabledTests: XCTestCase {
    func testAStoredEnabledKeyIsSkippedAndNeverWrittenBack() throws {
        // Each entry decodes, the switched-off one like the others, and
        // the palette goes back out without the key.
        let wire = #"[{"color":"red","enabled":false,"label":"Off","slot":"cabal-flag-01"},"#
            + #"{"color":"blue","enabled":true,"label":"On","slot":"cabal-flag-02"}]"#
        let decoded = try XCTUnwrap(FlagPalette.decode(wire))
        XCTAssertEqual(decoded, [
            FlagPaletteEntry(slot: "cabal-flag-01", label: "Off", color: "red"),
            FlagPaletteEntry(slot: "cabal-flag-02", label: "On", color: "blue"),
        ])
        XCTAssertEqual(
            FlagPalette.encode(decoded),
            #"[{"color":"red","label":"Off","slot":"cabal-flag-01"},"#
                + #"{"color":"blue","label":"On","slot":"cabal-flag-02"}]"#
        )
    }

    func testAFlagStoredAsSwitchedOffIsTheDefaultWhenItIsFirst() throws {
        // Position is the whole rule. A stored `enabled: false` is not
        // read, so the first entry is the default whatever it says, and a
        // palette whose every entry says so still has a default flag.
        let wire = #"[{"color":"red","enabled":false,"label":"Off","slot":"cabal-flag-01"},"#
            + #"{"color":"yellow","enabled":false,"label":"Flagged","slot":"\\Flagged"}]"#
        let stored = try XCTUnwrap(FlagPalette.decode(wire))
        XCTAssertEqual(FlagPalette.defaultEntry(in: stored).slot, "cabal-flag-01")
        XCTAssertEqual(
            FlagPalette.defaultEntry(in: Array(stored.dropFirst())),
            FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Flagged", color: "yellow")
        )
    }
}
