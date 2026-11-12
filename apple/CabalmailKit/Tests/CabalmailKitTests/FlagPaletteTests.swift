import XCTest
@testable import CabalmailKit

/// Wire marshalling for the custom-flag palette (rules-composition plan,
/// Phase 3) plus the `Preferences` payload-inclusion rule that keeps an
/// old server from 400ing the whole preferences push.
@MainActor
final class FlagPaletteTests: XCTestCase {
    private static let domain = "cabal.example.com"

    private func makeActivated() -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.activate(controlDomain: Self.domain, username: "chris")
        return preferences
    }

    private func samplePalette() -> [FlagPaletteEntry] {
        [
            FlagPaletteEntry(slot: "cabal-flag-01", label: "Urgent", color: "red"),
            FlagPaletteEntry(slot: "cabal-flag-02", label: "Waiting", color: "blue"),
        ]
    }

    // MARK: - Marshalling

    func testEncodeDecodeRoundTrip() {
        let palette = samplePalette()
        let decoded = FlagPalette.decode(FlagPalette.encode(palette))
        XCTAssertEqual(decoded, palette)
    }

    func testEncodeMatchesServerCanonicalShape() {
        // Compact, object keys sorted, array order preserved — the same
        // canonical form `set_preferences` re-serializes to. Three keys an
        // entry: no `enabled`, which the server deprecated and stops
        // accepting in 2.0.
        let wire = FlagPalette.encode([
            FlagPaletteEntry(slot: "cabal-flag-02", label: "B", color: "blue"),
            FlagPaletteEntry(slot: "cabal-flag-01", label: "A", color: "red"),
        ])
        XCTAssertEqual(
            wire,
            #"[{"color":"blue","label":"B","slot":"cabal-flag-02"},"#
                + #"{"color":"red","label":"A","slot":"cabal-flag-01"}]"#
        )
    }

    func testDecodeCarriesAnUnknownColor() throws {
        // An unknown color (a newer server's vocabulary) is carried, not
        // coerced.
        let wire = #"[{"slot":"cabal-flag-03","label":"New","color":"chartreuse"}]"#
        let decoded = try XCTUnwrap(FlagPalette.decode(wire))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].color, "chartreuse")
        // ...and the unknown color round-trips back out unchanged.
        XCTAssertTrue(FlagPalette.encode(decoded).contains("chartreuse"))
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(FlagPalette.decode("not json"))
        XCTAssertNil(FlagPalette.decode(#"{"slot":"x"}"#))
    }

    func testSlotsInFlagsFiltersAndOrders() {
        // Slot order is fixed regardless of set iteration order; system
        // flags and foreign keywords never leak through.
        let flags: Set<Flag> = [
            .seen, .flagged, .keyword("cabal-flag-07"),
            .keyword("cabal-flag-02"), .keyword("$Forwarded"),
        ]
        XCTAssertEqual(FlagPalette.slots(in: flags),
                       ["cabal-flag-02", "cabal-flag-07"])
        XCTAssertEqual(FlagPalette.slots(in: [.seen]), [])
    }

    func testFirstFreeSlotSkipsUsedAndCapsAtTwenty() {
        XCTAssertEqual(FlagPalette.firstFreeSlot(in: []), "cabal-flag-01")
        XCTAssertEqual(FlagPalette.firstFreeSlot(in: samplePalette()), "cabal-flag-03")
        let full = FlagPalette.slots.map {
            FlagPaletteEntry(slot: $0, label: "x", color: "red")
        }
        XCTAssertEqual(full.count, 20)
        XCTAssertNil(FlagPalette.firstFreeSlot(in: full))
    }

    func testFirstFreeSlotIgnoresTheSystemEntry() {
        // The system flag's entry takes no keyword slot: it neither uses
        // one up nor is ever handed out as free.
        let system = FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Urgent", color: "red")
        XCTAssertEqual(FlagPalette.firstFreeSlot(in: [system]), "cabal-flag-01")
        XCTAssertEqual(FlagPalette.firstFreeSlot(in: [system] + samplePalette()), "cabal-flag-03")
        let full = [system] + FlagPalette.slots.map {
            FlagPaletteEntry(slot: $0, label: "x", color: "red")
        }
        XCTAssertEqual(full.count, FlagPalette.maxEntries)
        XCTAssertNil(FlagPalette.firstFreeSlot(in: full))
        XCTAssertFalse(FlagPalette.slots.contains(FlagPalette.systemSlot))
    }

    // MARK: - The system flag's entry

    private func system(label: String = "Flagged", color: String = "yellow") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: FlagPalette.systemSlot, label: label, color: color)
    }

    func testSystemSlotIsTheFlaggedAtom() {
        // The server accepts exactly this spelling as a palette slot
        // (set_preferences, FLAG_PALETTE_SYSTEM_SLOT), and `set_flag`
        // takes it as the system flag.
        XCTAssertEqual(FlagPalette.systemSlot, "\\Flagged")
        XCTAssertEqual(Flag(wireValue: FlagPalette.systemSlot), .flagged)
        XCTAssertEqual(Flag(wireValue: "cabal-flag-04"), .keyword("cabal-flag-04"))
        XCTAssertEqual(FlagPalette.defaultSystemEntry, system())
        XCTAssertTrue(FlagPalette.colors.contains(FlagPalette.defaultSystemEntry.color))
    }

    func testEffectivePaletteSuppliesTheSystemEntryFirst() {
        XCTAssertEqual(FlagPalette.effective([]), [system()])
        XCTAssertEqual(FlagPalette.effective(samplePalette()), [system()] + samplePalette())
    }

    func testEffectivePaletteLeavesAStoredSystemEntryWhereItIs() {
        let stored = [samplePalette()[0], system(label: "Urgent", color: "red"), samplePalette()[1]]
        XCTAssertEqual(FlagPalette.effective(stored), stored)
        // Idempotent: the effective palette is its own effective palette.
        XCTAssertEqual(
            FlagPalette.effective(FlagPalette.effective(samplePalette())),
            FlagPalette.effective(samplePalette())
        )
    }

    func testKeywordEntriesLeaveOutTheSystemEntry() {
        XCTAssertEqual(FlagPalette.keywordEntries(in: samplePalette()), samplePalette())
        // Left out wherever it sits; the rest keep the palette's order.
        let stored = [samplePalette()[1], system(label: "Urgent", color: "red"), samplePalette()[0]]
        XCTAssertEqual(
            FlagPalette.keywordEntries(in: stored).map(\.slot),
            ["cabal-flag-02", "cabal-flag-01"]
        )
    }

    func testDefaultEntryIsTheFirstEntry() {
        // Untouched palette: the system flag, as before the palette had it.
        XCTAssertEqual(FlagPalette.defaultEntry(in: []), system())
        XCTAssertEqual(FlagPalette.defaultEntry(in: samplePalette()), system())
        // Another flag moved to the top takes over.
        let reordered = [samplePalette()[0], system()]
        XCTAssertEqual(FlagPalette.defaultEntry(in: reordered).slot, "cabal-flag-01")
        XCTAssertEqual(
            FlagPalette.defaultEntry(in: [samplePalette()[1], system()]).slot,
            "cabal-flag-02"
        )
    }

    func testEditingAnotherFlagDoesNotStoreTheSystemEntry() throws {
        // What the user sees has the system entry; what is stored must
        // not gain it from an edit that never touched it.
        let stored = samplePalette()
        var edited = FlagPalette.effective(stored)
        edited[1].label = "Now"
        edited.append(FlagPaletteEntry(slot: "cabal-flag-03", label: "Later", color: "teal"))
        let result = FlagPalette.stored(afterEditing: edited, from: stored)
        XCTAssertEqual(result.map(\.slot), ["cabal-flag-01", "cabal-flag-02", "cabal-flag-03"])
        XCTAssertEqual(result[0].label, "Now")
    }

    func testNoOpEditLeavesTheWireStringByteIdentical() throws {
        let wire = FlagPalette.encode(samplePalette())
        let stored = try XCTUnwrap(FlagPalette.decode(wire))
        let result = FlagPalette.stored(afterEditing: FlagPalette.effective(stored), from: stored)
        XCTAssertEqual(FlagPalette.encode(result), wire)
        XCTAssertFalse(FlagPalette.encode(result).contains("Flagged"))
        // The empty palette too.
        XCTAssertEqual(FlagPalette.stored(afterEditing: FlagPalette.effective([]), from: []), [])
    }

    func testEditingTheSystemEntryStoresItInPlace() {
        let stored = samplePalette()
        // Renamed or recoloured: stored first, where it sat.
        for changed in [system(label: "Urgent"), system(color: "red")] {
            var edited = FlagPalette.effective(stored)
            edited[0] = changed
            XCTAssertEqual(
                FlagPalette.stored(afterEditing: edited, from: stored),
                [changed] + stored
            )
        }
        // Moved, otherwise untouched: its place is the edit, so it is
        // stored there rather than re-supplied in first place.
        let moved = [stored[0], system(), stored[1]]
        XCTAssertEqual(FlagPalette.stored(afterEditing: moved, from: stored), moved)
    }

    func testAStoredSystemEntryStaysStoredOnceBackAtTheDefault() {
        // Put back by hand to the default, in first place: it stays on the
        // wire, because only Reset removes it.
        let previous = [system(label: "Urgent")] + samplePalette()
        let edited = [system()] + samplePalette()
        XCTAssertEqual(FlagPalette.stored(afterEditing: edited, from: previous), edited)
    }

    func testResetRemovesTheStoredSystemEntry() {
        let stored = [samplePalette()[0], system(label: "Urgent", color: "red"), samplePalette()[1]]
        let reset = FlagPalette.resettingSystemEntry(in: stored)
        XCTAssertEqual(reset, samplePalette())
        // ...so the default takes over again, in first place.
        XCTAssertEqual(FlagPalette.effective(reset), [system()] + samplePalette())
        XCTAssertEqual(FlagPalette.resettingSystemEntry(in: samplePalette()), samplePalette())
    }

    func testStoredSystemEntryRoundTripsOnTheWire() throws {
        let palette = [system(label: "Urgent", color: "red"), samplePalette()[0]]
        let wire = FlagPalette.encode(palette)
        // One backslash in the atom, escaped once by JSON.
        XCTAssertTrue(wire.hasPrefix(
            #"[{"color":"red","label":"Urgent","slot":"\\Flagged"}"#
        ))
        XCTAssertEqual(try XCTUnwrap(FlagPalette.decode(wire)), palette)
    }

    func testSlotsInPaletteOrderIncludeTheSystemFlag() {
        let flags: Set<Flag> = [
            .seen, .flagged, .keyword("cabal-flag-02"), .keyword("cabal-flag-01"),
            .keyword("$Forwarded"),
        ]
        // Untouched palette: the system flag leads, then palette order.
        XCTAssertEqual(
            FlagPalette.slots(in: flags, palette: samplePalette()),
            [FlagPalette.systemSlot, "cabal-flag-01", "cabal-flag-02"]
        )
        // Palette order, not slot order.
        let reordered = [samplePalette()[1], system(), samplePalette()[0]]
        XCTAssertEqual(
            FlagPalette.slots(in: flags, palette: reordered),
            ["cabal-flag-02", FlagPalette.systemSlot, "cabal-flag-01"]
        )
        // Not flagged: no system slot.
        XCTAssertEqual(
            FlagPalette.slots(in: [.keyword("cabal-flag-01")], palette: samplePalette()),
            ["cabal-flag-01"]
        )
        XCTAssertEqual(FlagPalette.slots(in: [.seen], palette: samplePalette()), [])
    }

    func testSlotsThePaletteNoLongerListsComeLastInSlotOrder() {
        // A tag whose palette entry was deleted is still on the message
        // and still has to be removable.
        let flags: Set<Flag> = [
            .flagged, .keyword("cabal-flag-09"), .keyword("cabal-flag-02"),
            .keyword("cabal-flag-05"),
        ]
        XCTAssertEqual(
            FlagPalette.slots(in: flags, palette: samplePalette()),
            [FlagPalette.systemSlot, "cabal-flag-02", "cabal-flag-05", "cabal-flag-09"]
        )
    }

    // MARK: - Preferences integration

    func testPayloadOmitsFlagPaletteUntilServerOrUserIntroducesIt() {
        // A server that predates the key 400s the whole app map on it, so
        // an empty palette on a fresh session must not ride the payload.
        let preferences = makeActivated()
        XCTAssertNil(preferences.appPreferencesPayload()["flag_palette"])

        // A local palette is an explicit user act; it rides.
        preferences.flagPalette = samplePalette()
        XCTAssertEqual(
            preferences.appPreferencesPayload()["flag_palette"],
            FlagPalette.encode(samplePalette())
        )

        // Emptying it again still rides — the server has stored a palette
        // by now, and omitting the key would resurrect it on the next pull.
        preferences.flagPalette = []
        XCTAssertEqual(preferences.appPreferencesPayload()["flag_palette"], "[]")
    }

    func testRemotePaletteAppliesAndUnlocksThePayloadKey() {
        let preferences = makeActivated()
        preferences.applyRemote(["flag_palette": FlagPalette.encode(samplePalette())])
        XCTAssertEqual(preferences.flagPalette, samplePalette())
        // The server has proven it knows the key: an empty palette now
        // rides so a deletion can sync.
        preferences.flagPalette = []
        XCTAssertEqual(preferences.appPreferencesPayload()["flag_palette"], "[]")
    }

    func testRemoteGarbageLeavesPaletteUntouched() {
        let preferences = makeActivated()
        preferences.flagPalette = samplePalette()
        preferences.applyRemote(["flag_palette": "not json"])
        XCTAssertEqual(preferences.flagPalette, samplePalette())
    }

    func testPayloadCarriesAStoredSystemEntryAndOmitsAnUnstoredOne() {
        // The default entry the user sees is never pushed on its own...
        let preferences = makeActivated()
        preferences.flagPalette = FlagPalette.stored(
            afterEditing: FlagPalette.effective(samplePalette()), from: samplePalette()
        )
        XCTAssertEqual(
            preferences.appPreferencesPayload()["flag_palette"],
            FlagPalette.encode(samplePalette())
        )
        // ...and an edited one rides and applies like any other entry.
        let edited = [system(label: "Urgent", color: "red")] + samplePalette()
        preferences.flagPalette = edited
        XCTAssertEqual(preferences.appPreferencesPayload()["flag_palette"], FlagPalette.encode(edited))

        let other = makeActivated()
        other.applyRemote(["flag_palette": FlagPalette.encode(edited)])
        XCTAssertEqual(other.flagPalette, edited)
        XCTAssertEqual(FlagPalette.defaultEntry(in: other.flagPalette).label, "Urgent")
    }

    func testPalettePersistsAndReloads() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: Self.domain, username: "chris")
        preferences.flagPalette = samplePalette()

        let second = Preferences(store: store)
        second.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertEqual(second.flagPalette, samplePalette())
    }
}
