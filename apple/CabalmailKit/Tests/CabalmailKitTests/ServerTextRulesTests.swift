import XCTest
@testable import CabalmailKit

/// The typed values `set_preferences` refuses the whole settings map over
/// (#2439): a flag's name outside 1 to 32 code points or holding a control
/// character, a signature over 2,000 code points or holding a control
/// character other than newline and tab. `Preferences` holds every value
/// to those rules, so the app never sends one the server refuses.
@MainActor
final class ServerTextRulesTests: XCTestCase {
    /// A thumbs-up with a skin tone: one character, two code points.
    private let thumbsUp = "\u{1F44D}\u{1F3FD}"

    private func activated(_ store: InMemoryPreferenceStore = InMemoryPreferenceStore()) -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: "cabal.example.com", username: "alice")
        return preferences
    }

    // MARK: - The rules

    /// Before, a name was cut at 32 characters, and 20 of these are 40
    /// code points, which the server refuses.
    func testAFlagNameIsCutAtThirtyTwoCodePointsWithoutSplittingACharacter() {
        let name = String(repeating: thumbsUp, count: 20)
        XCTAssertEqual(name.count, 20)

        let accepted = ServerTextRules.flagLabel(name)

        XCTAssertEqual(accepted, String(repeating: thumbsUp, count: 16))
        XCTAssertEqual(accepted.unicodeScalars.count, 32)
    }

    func testACutStopsBeforeACharacterThatWouldCrossTheLimit() {
        // 31 code points, then a character of two: it does not fit whole.
        let name = String(repeating: "a", count: 31) + thumbsUp

        XCTAssertEqual(ServerTextRules.flagLabel(name), String(repeating: "a", count: 31))
    }

    func testAFlagNameLosesItsControlCharacters() {
        XCTAssertEqual(ServerTextRules.flagLabel("To\tdo\u{7F}\n"), "Todo")
        XCTAssertEqual(ServerTextRules.flagLabel("Short"), "Short")
    }

    func testASignatureIsCutAtTwoThousandCodePointsAndKeepsItsLines() {
        let line = String(repeating: "x", count: 48) + "\r\n"
        let signature = String(repeating: line, count: 50) + "\u{07}\tend"
        XCTAssertGreaterThan(signature.unicodeScalars.count, 2000)

        let accepted = ServerTextRules.signature(signature)

        XCTAssertEqual(accepted.unicodeScalars.count, 2000)
        XCTAssertFalse(accepted.contains("\r"))
        XCTAssertTrue(accepted.hasPrefix(String(repeating: "x", count: 48) + "\n"))
        XCTAssertEqual(ServerTextRules.signature("a\rb\u{07}\tc"), "a\nb\tc")
    }

    func testAnEmptyNameInAPaletteIsNamedAsANewFlagIs() {
        let palette = [FlagPaletteEntry(slot: "cabal-flag-01", label: "\t", color: "red")]

        XCTAssertEqual(FlagPalette.accepted(palette).map(\.label), [FlagPalette.newFlagLabel])
    }

    /// The built-in flag is not a new flag: its own default name is
    /// "Flagged", and that is what an empty one becomes (#2448). Its color
    /// and place are the user's and stay.
    func testTheBuiltInFlagWithAnEmptyNameIsNamedFlagged() {
        let palette = [
            FlagPaletteEntry(slot: "cabal-flag-01", label: "", color: "red"),
            FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "", color: "teal"),
        ]

        XCTAssertEqual(FlagPalette.accepted(palette), [
            FlagPaletteEntry(slot: "cabal-flag-01", label: "New flag", color: "red"),
            FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Flagged", color: "teal"),
        ])
    }

    // MARK: - Preferences holds to them

    func testPreferencesCutsASignatureAsItIsWrittenAndPersistsTheCut() {
        let store = InMemoryPreferenceStore()
        let preferences = activated(store)
        var changes = 0
        preferences.onLocalChange = { changes += 1 }

        preferences.signature = String(repeating: "s", count: 2500)

        XCTAssertEqual(preferences.signature.unicodeScalars.count, 2000)
        XCTAssertEqual(preferences.appPreferencesPayload()["signature"], preferences.signature)
        XCTAssertEqual(changes, 1, "one write, one push")
        XCTAssertEqual(activated(store).signature, preferences.signature, "the cut is what was stored")
    }

    func testPreferencesCutsAFlagNameAsItIsWrittenAndPersistsTheCut() {
        let store = InMemoryPreferenceStore()
        let preferences = activated(store)
        var changes = 0
        preferences.onLocalChange = { changes += 1 }

        preferences.flagPalette = [
            FlagPaletteEntry(slot: "cabal-flag-01", label: String(repeating: thumbsUp, count: 20), color: "red"),
        ]

        let label = preferences.flagPalette.first?.label
        XCTAssertEqual(label?.unicodeScalars.count, 32)
        XCTAssertEqual(changes, 1, "one write, one push")
        XCTAssertEqual(activated(store).flagPalette.first?.label, label, "the cut is what was stored")
    }

    /// 1.52.0 could store a flag with an empty name, which no push from
    /// that device could carry. The next launch names it.
    func testAnEmptyNameAnOlderBuildStoredIsNamedAtLaunch() throws {
        let store = InMemoryPreferenceStore()
        let older = activated(store)
        let key = try XCTUnwrap(older.storageKey(.flagPalette))
        store.setString(#"[{"color":"red","label":"","slot":"cabal-flag-01"}]"#, forKey: key)

        let launched = activated(store)

        XCTAssertEqual(launched.flagPalette.map(\.label), [FlagPalette.newFlagLabel])
        let wire = try XCTUnwrap(launched.appPreferencesPayload()["flag_palette"])
        XCTAssertTrue(wire.contains(#""label":"New flag""#))
    }

    /// The same for the built-in flag, whose name 1.52.0 could clear too:
    /// it launches as "Flagged", and that is what the next push carries.
    func testTheBuiltInFlagAnOlderBuildStoredWithAnEmptyNameIsFlaggedAtLaunch() throws {
        let store = InMemoryPreferenceStore()
        let older = activated(store)
        let key = try XCTUnwrap(older.storageKey(.flagPalette))
        store.setString(#"[{"color":"red","label":"","slot":"\\Flagged"}]"#, forKey: key)

        let launched = activated(store)

        XCTAssertEqual(launched.flagPalette.map(\.label), ["Flagged"])
        let wire = try XCTUnwrap(launched.appPreferencesPayload()["flag_palette"])
        XCTAssertTrue(wire.contains(#""label":"Flagged""#))
    }

    /// A signature an older build stored past the limit is cut at launch.
    func testALongSignatureAnOlderBuildStoredIsCutAtLaunch() throws {
        let store = InMemoryPreferenceStore()
        let older = activated(store)
        let key = try XCTUnwrap(older.storageKey(.signature))
        store.setString(String(repeating: "s", count: 2400), forKey: key)

        let launched = activated(store)

        XCTAssertEqual(launched.signature.unicodeScalars.count, 2000)
    }
}
