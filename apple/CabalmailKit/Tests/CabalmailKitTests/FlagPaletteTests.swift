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
            FlagPaletteEntry(slot: "cabal-flag-02", label: "Waiting", color: "blue", enabled: false),
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
        // canonical form `set_preferences` re-serializes to.
        let wire = FlagPalette.encode([
            FlagPaletteEntry(slot: "cabal-flag-02", label: "B", color: "blue"),
            FlagPaletteEntry(slot: "cabal-flag-01", label: "A", color: "red", enabled: false),
        ])
        XCTAssertEqual(
            wire,
            #"[{"color":"blue","enabled":true,"label":"B","slot":"cabal-flag-02"},"#
                + #"{"color":"red","enabled":false,"label":"A","slot":"cabal-flag-01"}]"#
        )
    }

    func testDecodeToleratesMissingEnabledAndUnknownColor() throws {
        // `enabled` defaults true like the server; an unknown color (a
        // newer server's vocabulary) is carried, not coerced.
        let wire = #"[{"slot":"cabal-flag-03","label":"New","color":"chartreuse"}]"#
        let decoded = try XCTUnwrap(FlagPalette.decode(wire))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertTrue(decoded[0].enabled)
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
        XCTAssertEqual(full.count, FlagPalette.maxEntries)
        XCTAssertNil(FlagPalette.firstFreeSlot(in: full))
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
