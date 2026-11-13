import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `FlagNameField`: the state behind the flag editor's name field. The
/// editor keeps one in `@State` and does nothing with the name itself, so
/// what these drive is what the editor does (#2448).
///
/// A field left empty gives the flag back the name it opened with (#2439),
/// but a name the flag got from elsewhere in the meantime, by Reset to
/// Default or by a pull, is newer than that and has to stay.
@MainActor
final class FlagNameFieldTests: XCTestCase {
    private let own = "cabal-flag-01"
    private let system = FlagPalette.systemSlot

    private func entry(_ slot: String, _ label: String, color: String = "blue") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: slot, label: label, color: color)
    }

    private func preferences(_ palette: [FlagPaletteEntry]) -> Preferences {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.flagPalette = palette
        return preferences
    }

    /// The name the list shows for `slot`.
    private func name(of slot: String, in prefs: Preferences) -> String? {
        FlagPaletteEntryBindings(preferences: prefs, slot: slot).entry?.label
    }

    /// Empties the field the two ways a user can: select all and delete,
    /// which writes nothing on the way, or Backspace one character at a
    /// time, which stores each shorter name until one character is left.
    private func empty(_ field: inout FlagNameField, byBackspace: Bool) {
        guard byBackspace else {
            field.text = ""
            return
        }
        var text = field.text
        while !text.isEmpty {
            text.removeLast()
            field.text = text
        }
    }

    /// A pull that brings `palette`, as the sync coordinator applies one.
    private func pull(_ palette: [FlagPaletteEntry], into prefs: Preferences) {
        prefs.applyRemote(["flag_palette": FlagPalette.encode(palette)])
    }

    // MARK: - A field left empty (#2439)

    func testAnEmptiedFieldShowsNothingWhileTheFlagKeepsAName() {
        let prefs = preferences([entry(own, "Later")])
        var field = FlagNameField(preferences: prefs, slot: own)
        XCTAssertEqual(field.text, "Later")

        empty(&field, byBackspace: true)

        XCTAssertEqual(field.text, "")
        XCTAssertEqual(name(of: own, in: prefs), "L", "the last name the field wrote")
    }

    func testLeavingWithTheFieldEmptiedGivesBackTheOpeningName() {
        for byBackspace in [false, true] {
            let prefs = preferences([entry(own, "Later")])
            var field = FlagNameField(preferences: prefs, slot: own)

            empty(&field, byBackspace: byBackspace)
            field.leave()

            XCTAssertEqual(name(of: own, in: prefs), "Later", "byBackspace: \(byBackspace)")
        }
    }

    func testANameTypedAfterEmptyingIsKept() {
        let prefs = preferences([entry(own, "Later")])
        var field = FlagNameField(preferences: prefs, slot: own)

        empty(&field, byBackspace: true)
        field.text = "Groceries"
        XCTAssertEqual(field.text, "Groceries")
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Groceries")
    }

    /// A long name is stored cut, so the stored name is not the typed one.
    /// It is still the field's own, and the opening name still comes back.
    func testANameTheRulesCutIsNotTakenForANameFromElsewhere() {
        let prefs = preferences([entry(own, "Later")])
        var field = FlagNameField(preferences: prefs, slot: own)

        field.text = String(repeating: "x", count: FlagPalette.maxLabelLength + 8)
        field.text = ""
        XCTAssertEqual(field.text, "")
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Later")
    }

    /// Only the name counts: another edit to the flag is not a new name.
    func testAColorChangeWhileTheFieldIsEmptyLeavesItEmpty() {
        let prefs = preferences([entry(own, "Later")])
        var field = FlagNameField(preferences: prefs, slot: own)

        empty(&field, byBackspace: true)
        FlagPaletteEntryBindings(preferences: prefs, slot: own).set(\.color, to: "teal")
        XCTAssertEqual(field.text, "")
        field.leave()

        XCTAssertEqual(prefs.flagPalette, [entry(own, "Later", color: "teal")])
    }

    /// Leaving settles the name. If the same editor is shown again, the
    /// name to give back is the one the flag has then.
    func testALaterVisitOpensOnTheNameTheFlagHasThen() {
        let prefs = preferences([entry(own, "Later")])
        var field = FlagNameField(preferences: prefs, slot: own)

        field.text = "Groceries"
        field.leave()
        empty(&field, byBackspace: true)
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Groceries")
    }

    // MARK: - Reset to Default (#2448)

    /// The issue's steps: the built-in flag was renamed earlier, its field
    /// is emptied and Reset to Default tapped. Before, the field stayed
    /// blank, and leaving wrote "Urgent" back over the reset and pushed it.
    func testResetWithTheFieldEmptiedIsNotUndoneOnLeaving() {
        for byBackspace in [false, true] {
            let prefs = preferences([entry(own, "Alpha"), entry(system, "Urgent", color: "red")])
            var field = FlagNameField(preferences: prefs, slot: system)

            empty(&field, byBackspace: byBackspace)
            field.resetToDefault()
            XCTAssertEqual(field.text, "Flagged", "the field shows the default name")

            var writes = 0
            prefs.onLocalChange = { writes += 1 }
            field.leave()

            XCTAssertEqual(
                prefs.flagPalette, [entry(own, "Alpha")],
                "the built-in flag keeps its default name, color and place (byBackspace: \(byBackspace))"
            )
            XCTAssertEqual(writes, 0, "leaving has nothing to write")
        }
    }

    /// The same with Reset tapped first. Before, leaving gave back the
    /// name the editor opened on, which the reset had replaced.
    func testAFieldEmptiedAfterResetGivesBackTheDefaultName() {
        for byBackspace in [false, true] {
            let prefs = preferences([entry(system, "Urgent", color: "red"), entry(own, "Alpha")])
            var field = FlagNameField(preferences: prefs, slot: system)

            field.resetToDefault()
            empty(&field, byBackspace: byBackspace)
            XCTAssertEqual(field.text, "")
            field.leave()

            XCTAssertEqual(name(of: system, in: prefs), "Flagged", "byBackspace: \(byBackspace)")
        }
    }

    /// The field had been typed in before the reset, so it had a name to
    /// give back already. The default name replaces it.
    func testResetReplacesTheNameAUsedFieldWouldGiveBack() {
        let prefs = preferences([entry(system, "Urgent", color: "red")])
        var field = FlagNameField(preferences: prefs, slot: system)

        field.text = "Urgently"
        field.resetToDefault()
        empty(&field, byBackspace: true)
        field.leave()

        XCTAssertEqual(name(of: system, in: prefs), "Flagged")
    }

    /// Only the color was changed, so the reset leaves the name as it was:
    /// "Flagged". The emptied field shows it all the same, and leaving has
    /// nothing to write.
    func testResetShowsTheDefaultNameWhenTheNameWasAlreadyTheDefault() {
        let prefs = preferences([entry(system, "Flagged", color: "red")])
        var field = FlagNameField(preferences: prefs, slot: system)
        empty(&field, byBackspace: false)

        field.resetToDefault()
        XCTAssertEqual(field.text, "Flagged")

        var writes = 0
        prefs.onLocalChange = { writes += 1 }
        field.leave()

        XCTAssertEqual(prefs.flagPalette, [])
        XCTAssertEqual(writes, 0, "leaving has nothing to write")
    }

    /// Reset is the built-in flag's alone, and is offered only once that
    /// flag has been changed. Elsewhere it does nothing, to the flag or to
    /// an emptied field.
    func testResetWithNothingToResetChangesNothing() {
        let prefs = preferences([entry(own, "Alpha")])
        var field = FlagNameField(preferences: prefs, slot: own)
        empty(&field, byBackspace: false)

        field.resetToDefault()

        XCTAssertEqual(field.text, "")
        XCTAssertEqual(prefs.flagPalette, [entry(own, "Alpha")])
    }

    // MARK: - A rename that arrives by a pull (#2448)

    /// Another device renames the flag while this one's field sits empty.
    /// Before, leaving wrote the opening name over the rename and pushed
    /// it.
    func testARenameThatArrivesWhileTheFieldIsEmptyIsKeptOnLeaving() {
        for byBackspace in [false, true] {
            let prefs = preferences([entry(own, "Work")])
            var field = FlagNameField(preferences: prefs, slot: own)
            empty(&field, byBackspace: byBackspace)

            pull([entry(own, "Projects")], into: prefs)
            XCTAssertEqual(field.text, "Projects", "the field shows the newer name")

            var writes = 0
            prefs.onLocalChange = { writes += 1 }
            field.leave()

            XCTAssertEqual(name(of: own, in: prefs), "Projects", "byBackspace: \(byBackspace)")
            XCTAssertEqual(writes, 0, "leaving has nothing to write")
        }
    }

    /// The pull that follows this device's own push brings back the name
    /// the field last wrote. That is no rename: the field stays empty and
    /// leaving still gives back the opening name.
    func testAPullOfTheFieldsOwnLastNameLeavesTheFieldEmpty() {
        let prefs = preferences([entry(own, "Work")])
        var field = FlagNameField(preferences: prefs, slot: own)
        empty(&field, byBackspace: true)

        pull([entry(own, "W")], into: prefs)
        XCTAssertEqual(field.text, "")
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Work")
    }

    /// A rename that arrives before the field is touched is the name the
    /// editor is open on.
    func testARenameThatArrivesBeforeTheFieldIsEmptiedIsTheNameGivenBack() {
        let prefs = preferences([entry(own, "Work")])
        var field = FlagNameField(preferences: prefs, slot: own)

        pull([entry(own, "Projects")], into: prefs)
        empty(&field, byBackspace: true)
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Projects")
    }

    /// The field had been typed in before the pull, so it had a name to
    /// give back already. The rename replaces it.
    func testARenameThatArrivesReplacesTheNameAUsedFieldWouldGiveBack() {
        let prefs = preferences([entry(own, "Work")])
        var field = FlagNameField(preferences: prefs, slot: own)

        field.text = "Works"
        pull([entry(own, "Projects")], into: prefs)
        empty(&field, byBackspace: true)
        field.leave()

        XCTAssertEqual(name(of: own, in: prefs), "Projects")
    }

    /// Deleted on another device with the editor open: the field reads
    /// empty and nothing it does brings the flag back.
    func testAFieldWhoseFlagIsGoneWritesNothing() {
        let prefs = preferences([entry(own, "Alpha"), entry("cabal-flag-02", "Beta")])
        var field = FlagNameField(preferences: prefs, slot: "cabal-flag-02")
        empty(&field, byBackspace: true)

        pull([entry(own, "Alpha")], into: prefs)
        XCTAssertEqual(field.text, "")
        field.text = "Ghost"
        field.leave()

        XCTAssertEqual(prefs.flagPalette, [entry(own, "Alpha")])
    }

    // MARK: - Text that is not a name (#2448)

    /// One character of 41 code points: no whole character fits in 32.
    private let overlongCharacter = "e" + String(repeating: "\u{301}", count: 40)

    /// Text the server's rules reduce to nothing is no more a name than
    /// empty text is. Before, it passed for one, and the flag was renamed
    /// "New flag".
    func testTextTheRulesReduceToNothingEmptiesTheFieldAndWritesNothing() {
        XCTAssertEqual(overlongCharacter.count, 1)
        for text in ["\t", "\u{7F}\n", overlongCharacter] {
            let prefs = preferences([entry(own, "Later")])
            var field = FlagNameField(preferences: prefs, slot: own)
            var writes = 0
            prefs.onLocalChange = { writes += 1 }

            field.text = text

            XCTAssertEqual(field.text, "")
            XCTAssertEqual(name(of: own, in: prefs), "Later")
            XCTAssertEqual(writes, 0)
        }
    }

    func testTheNameBindingWritesNoTextTheRulesReduceToNothing() {
        let prefs = preferences([entry(own, "Later")])
        let bindings = FlagPaletteEntryBindings(preferences: prefs, slot: own)
        var writes = 0
        prefs.onLocalChange = { writes += 1 }

        bindings.label.wrappedValue = "\t"
        bindings.label.wrappedValue = overlongCharacter

        XCTAssertEqual(prefs.flagPalette, [entry(own, "Later")])
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(FlagPaletteEntryBindings.isName(""))
        XCTAssertTrue(FlagPaletteEntryBindings.isName("To\tdo"), "a control character among letters is dropped")
    }
}
