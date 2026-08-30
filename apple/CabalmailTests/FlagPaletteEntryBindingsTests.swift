import XCTest
import SwiftUI
import CabalmailKit
@testable import Cabalmail

/// `FlagPaletteEntryBindings`: the palette editor's accessors stay total
/// once the entry they address is gone (#1340 — index-capturing bindings
/// trapped with "Index out of range" whenever the deleted entry was the
/// last one, taking the app down and losing the delete).
@MainActor
final class FlagPaletteEntryBindingsTests: XCTestCase {
    private func entry(
        _ slot: String, _ label: String, color: String = "blue", enabled: Bool = true
    ) -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color, enabled: enabled)
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
            entry("cabal-flag-02", "Beta", enabled: false),
        ])
        let second = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        XCTAssertEqual(second.entry?.label, "Beta")
        XCTAssertEqual(second.label.wrappedValue, "Beta")
        XCTAssertFalse(second.value(\.enabled, or: true).wrappedValue)
    }

    func testWritesReachTheAddressedEntryAndLeaveSiblingsAlone() {
        let prefs = preferences([
            entry("cabal-flag-01", "Alpha"),
            entry("cabal-flag-02", "Beta"),
        ])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: "cabal-flag-02")
        bindings.label.wrappedValue = "Renamed"
        bindings.value(\.enabled, or: true).wrappedValue = false
        bindings.set(\.color, to: "teal")

        XCTAssertEqual(prefs.flagPalette.map(\.label), ["Alpha", "Renamed"])
        XCTAssertEqual(prefs.flagPalette.map(\.enabled), [true, false])
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
        XCTAssertTrue(bindings.value(\.enabled, or: true).wrappedValue)
        XCTAssertEqual(bindings.value(\.color, or: "gray").wrappedValue, "gray")
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
        bindings.value(\.enabled, or: true).wrappedValue = false
        bindings.set(\.color, to: "pink")

        XCTAssertEqual(prefs.flagPalette.count, 1)
        XCTAssertEqual(prefs.flagPalette[0].label, "Alpha")
        XCTAssertTrue(prefs.flagPalette[0].enabled)
        XCTAssertEqual(prefs.flagPalette[0].color, "blue")
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
