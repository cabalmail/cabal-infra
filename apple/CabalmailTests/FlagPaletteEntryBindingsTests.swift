import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// `FlagPaletteEntryBindings`: the palette editor's accessors stay total
/// once the entry they address is gone (#1340 — index-capturing bindings
/// trapped with "Index out of range" whenever the deleted entry was the
/// last one, taking the app down and losing the delete).
@MainActor
final class FlagPaletteEntryBindingsTests: XCTestCase {
    private func entry(_ slot: String, _ label: String, color: String = "blue") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color)
    }

    private func preferences(_ palette: [FlagPaletteEntry]) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.flagPalette = palette
        return preferences
    }

    // MARK: - Reads and writes while the entry exists

    func testReadsTheAddressedEntryRegardlessOfItsPosition() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta", color: "teal"),
        ])
        let second = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        XCTAssertEqual(second.entry?.label, "Beta")
        XCTAssertEqual(second.label.wrappedValue, "Beta")
        XCTAssertEqual(second.entry?.color, "teal")
    }

    func testWritesReachTheAddressedEntryAndLeaveSiblingsAlone() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        bindings.label.wrappedValue = "Renamed"
        bindings.set(\.color, to: "teal")

        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha", "Renamed"])
        XCTAssertEqual(prefs.flagPalette.map(\.color), ["blue", "teal"])
    }

    func testLabelWritesAreCappedToTheServerLimit() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha")])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        bindings.label.wrappedValue = String(repeating: "x", count: FlagPalette.maxLabelLength + 10)
        XCTAssertEqual(prefs.flagPalette[0].label.count, FlagPalette.maxLabelLength)
    }

    // MARK: - The reported crash: the entry is gone and the editor is still mounted

    /// The exact 1-flag arm from the report: the only entry is deleted, so
    /// index 0 is past the end of an empty array. Pre-fix the still-mounted
    /// `TextField`'s getter read `flagPalette[0]` here and trapped.
    func testReadingTheOnlyEntryAfterItIsDeletedIsNeutralNotFatal() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha")])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        bindings.delete()

        XCTAssertTrue(prefs.flagPalette.isEmpty)
        XCTAssertNil(bindings.entry)
        XCTAssertEqual(bindings.label.wrappedValue, "")
    }

    /// The verifier's narrowing (#1340, 2026-08-30): deleting the *last*
    /// of two entries is the arm a fix guarding only the empty case would
    /// still crash on — index 1 into a one-element array.
    func testReadingTheLastOfTwoEntriesAfterItIsDeletedIsNeutralNotFatal() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        bindings.delete()

        XCTAssertEqual(prefs.flagPalette.map(\.slot), ["cabal-flag-01"])
        XCTAssertNil(bindings.entry)
        XCTAssertEqual(bindings.label.wrappedValue, "")
    }

    /// The non-crashing arm the verifier measured stays non-crashing, and
    /// keeps deleting the entry it was asked to delete rather than the one
    /// that happens to sit at the old index.
    func testDeletingANonLastEntryRemovesThatEntry() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        bindings.delete()

        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Beta"])
        XCTAssertNil(bindings.entry)
        XCTAssertEqual(bindings.label.wrappedValue, "")
    }

    /// The hazard the editor's `else` branch already named but could not
    /// cover: the entry vanishes from under a mounted editor because
    /// another device deleted it. Same read, same neutral answer.
    func testAnEntryRemovedByARemoteChangeReadsNeutrally() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        prefs.flagPalette = [entry("cabal-flag-01", "Alpha")]

        XCTAssertNil(bindings.entry)
        XCTAssertEqual(bindings.label.wrappedValue, "")
    }

    /// A write arriving after the entry is gone must not resurrect it, and
    /// must not scribble on whatever now occupies the old position.
    func testWritesAfterDeletionAreNoOps() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        bindings.delete()

        bindings.label.wrappedValue = "Ghost"
        bindings.set(\.color, to: "pink")

        XCTAssertEqual(prefs.flagPalette.count, 1)
        XCTAssertEqual(prefs.flagPalette[0].label, "Alpha")
        XCTAssertEqual(prefs.flagPalette[0].color, "blue")
    }

    // MARK: - Move Up / Move Down (the Mac's only reorder, #2019)

    func testMoveStepsTheAddressedEntry() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
            entry("cabal-flag-03", "Gamma"),
        ])
        FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-03").move(by: -1)
        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha", "Gamma", "Beta"])
        FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01").move(by: 1)
        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Gamma", "Alpha", "Beta"])
    }

    /// The ends disable their item, and a move that can't happen writes
    /// nothing, including once the entry is gone. The list's first row is
    /// the system flag's entry, so that is the one that cannot move up.
    func testMovePastEitherEndOrOnceGoneIsANoOp() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let first = FlagPaletteEntryBindings(preferences: prefs, slot: FlagPalette.systemSlot)
        let last = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        XCTAssertFalse(first.canMove(by: -1))
        XCTAssertTrue(first.canMove(by: 1))
        XCTAssertTrue(last.canMove(by: -1))
        XCTAssertFalse(last.canMove(by: 1))

        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }
        first.move(by: -1)
        last.move(by: 1)
        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha", "Beta"])

        last.delete()
        XCTAssertFalse(last.canMove(by: -1))
        last.move(by: -1)
        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha"])
        XCTAssertEqual(localChanges, 1, "only the delete should have written")
    }

    // MARK: - The system flag's entry

    private var system: FlagPaletteEntry { FlagPalette.defaultSystemEntry }

    private func systemBindings(_ prefs: Preferences) -> FlagPaletteEntryBindings {
        FlagPaletteEntryBindings(preferences: prefs, slot: FlagPalette.systemSlot)
    }

    func testTheSystemEntryIsEditableBeforeItIsStored() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha")])
        let bindings = systemBindings(prefs)
        XCTAssertTrue(bindings.isSystemEntry)
        XCTAssertEqual(bindings.entry, system)
        XCTAssertEqual(bindings.label.wrappedValue, "Flagged")
        XCTAssertFalse(bindings.canReset, "nothing stored, nothing to reset")
        XCTAssertFalse(
            FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01").isSystemEntry
        )
    }

    func testEditingTheSystemEntryStoresItFirst() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha")])
        let bindings = systemBindings(prefs)
        bindings.label.wrappedValue = "Urgent"
        bindings.set(\.color, to: "red")

        XCTAssertEqual(prefs.flagPalette.map(\.slot), [FlagPalette.systemSlot, "cabal-flag-01"])
        XCTAssertEqual(prefs.flagPalette[0].label, "Urgent")
        XCTAssertEqual(prefs.flagPalette[0].color, "red")
        XCTAssertTrue(bindings.canReset)
    }

    /// Editing some other flag is the common case, and must not put the
    /// untouched system entry on the wire.
    func testEditingAnotherFlagLeavesTheSystemEntryUnstored() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")])
        let alpha = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        alpha.label.wrappedValue = "Renamed"
        alpha.set(\.color, to: "teal")
        FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02").move(by: 1)

        XCTAssertEqual(prefs.flagPalette.map(\.slot), ["cabal-flag-01", "cabal-flag-02"])
        XCTAssertFalse(systemBindings(prefs).canReset)
    }

    /// Moving a flag above the system entry is an edit to the system
    /// entry's place, so the entry is stored where it now sits.
    func testMovingAFlagAboveTheSystemEntryStoresTheNewOrder() {
        let prefs = preferences([entry("cabal-flag-01", "Alpha"), entry("cabal-flag-02", "Beta")])
        let alpha = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        XCTAssertTrue(alpha.canMove(by: -1))
        alpha.move(by: -1)

        XCTAssertEqual(
            prefs.flagPalette.map(\.slot),
            ["cabal-flag-01", FlagPalette.systemSlot, "cabal-flag-02"]
        )
        XCTAssertEqual(prefs.flagPalette[1], system)

        // And the system entry moves like any other.
        systemBindings(prefs).move(by: 1)
        XCTAssertEqual(
            prefs.flagPalette.map(\.slot),
            ["cabal-flag-01", "cabal-flag-02", FlagPalette.systemSlot]
        )
    }

    func testResetDropsTheStoredSystemEntryAndWritesOnce() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry(FlagPalette.systemSlot, "Urgent", color: "red"),
        ])
        let bindings = systemBindings(prefs)
        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }

        bindings.reset()
        XCTAssertEqual(prefs.flagPalette.map(\.slot), ["cabal-flag-01"])
        XCTAssertEqual(bindings.entry, system, "the default entry takes over")
        XCTAssertFalse(bindings.canMove(by: -1), "back in first place")
        XCTAssertFalse(bindings.canReset)

        bindings.reset()
        XCTAssertEqual(localChanges, 1, "a second reset has nothing to write")
    }

    /// The system flag cannot be deleted: asked to, the entry resets, and
    /// reset is not offered for any other flag.
    func testDeleteOnTheSystemEntryResetsItAndResetOnAnotherDoesNothing() {
        let prefs = preferences([
            entry(FlagPalette.systemSlot, "Urgent"),
            entry("cabal-flag-01", "Alpha"),
        ])
        systemBindings(prefs).delete()
        XCTAssertEqual(prefs.flagPalette.map(\.slot), ["cabal-flag-01"])
        XCTAssertNotNil(systemBindings(prefs).entry)

        let alpha = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01")
        XCTAssertFalse(alpha.canReset)
        alpha.reset()
        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha"])
    }

    // MARK: - The delete has to be able to reach the server

    /// The report's second half: the crash beat the preferences push, so
    /// the delete was lost. An emptied palette still persists and still
    /// fires the local-change hook the sync coordinator debounces on.
    func testDeletingTheLastEntryPersistsTheEmptyPaletteAndSignalsSync() {
        let store = InMemoryPreferenceStore()
        let prefs = Preferences(store: store)
        prefs.activate(controlDomain: "admin.example.test", username: "chris")
        prefs.flagPalette = [entry("cabal-flag-01", "Alpha")]

        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }

        FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-01").delete()

        XCTAssertTrue(prefs.flagPalette.isEmpty)
        XCTAssertEqual(localChanges, 1)
        let reloaded = Preferences(store: store)
        reloaded.activate(controlDomain: "admin.example.test", username: "chris")
        XCTAssertTrue(reloaded.flagPalette.isEmpty)
    }
}
