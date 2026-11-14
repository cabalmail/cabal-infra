import XCTest
@testable import CabalmailKit

/// `SettingsSyncLedger`'s bookkeeping and `FlagPalette.merged`, on plain
/// values. `PreferencesUnsentKeysTests` holds the same rules through
/// `Preferences`; these cover the cases that are easier to state without
/// one.
final class SettingsSyncLedgerTests: XCTestCase {
    private func flag(_ number: Int, _ label: String, _ color: String = "blue") -> FlagPaletteEntry {
        FlagPaletteEntry(slot: String(format: "cabal-flag-%02d", number), label: label, color: color)
    }

    // MARK: - The flag list

    func testEachSidesOwnChangeSurvives() {
        let base = [flag(1, "Later"), flag(2, "Work")]
        let mine = [flag(1, "Soon"), flag(2, "Work")]
        let theirs = [flag(1, "Later"), flag(2, "Work", "red"), flag(3, "New")]

        XCTAssertEqual(FlagPalette.merged(base: base, mine: mine, theirs: theirs),
                       [flag(1, "Soon"), flag(2, "Work", "red"), flag(3, "New")])
    }

    func testADeleteOnEitherSideIsADelete() {
        let base = [flag(1, "Later"), flag(2, "Work"), flag(3, "Home")]
        let mine = [flag(1, "Later"), flag(3, "Home")]
        let theirs = [flag(1, "Later"), flag(2, "Work")]

        XCTAssertEqual(FlagPalette.merged(base: base, mine: mine, theirs: theirs), [flag(1, "Later")])
    }

    func testAFlagAddedOnEachSideIsKeptOnBoth() {
        let base = [flag(1, "Later")]
        let mine = [flag(1, "Later"), flag(2, "Mine")]
        let theirs = [flag(1, "Later"), flag(3, "Theirs")]

        XCTAssertEqual(FlagPalette.merged(base: base, mine: mine, theirs: theirs),
                       [flag(1, "Later"), flag(3, "Theirs"), flag(2, "Mine")])
    }

    /// Both changed the same flag, or both gave the same free slot to a
    /// new one: this device's wins, as its whole list did before.
    func testTheSameFlagChangedOnBothSidesIsThisDevices() {
        let base = [flag(1, "Later")]

        XCTAssertEqual(FlagPalette.merged(base: base, mine: [flag(1, "Mine")], theirs: [flag(1, "Theirs")]),
                       [flag(1, "Mine")])
        XCTAssertEqual(FlagPalette.merged(base: base,
                                          mine: [flag(1, "Later"), flag(2, "Mine")],
                                          theirs: [flag(1, "Later"), flag(2, "Theirs")]),
                       [flag(1, "Later"), flag(2, "Mine")])
        XCTAssertEqual(FlagPalette.merged(base: base, mine: [], theirs: [flag(1, "Theirs")]), [],
                       "deleted here, renamed there: the delete is this device's change")
    }

    /// The first flag in the list is the default flag, so the order is a
    /// setting too: this device's when it moved the flags, else the row's.
    func testTheOrderIsThisDevicesOnlyWhenItReordered() {
        let base = [flag(1, "A"), flag(2, "B"), flag(3, "C")]
        let theirs = [flag(3, "C"), flag(1, "A"), flag(2, "B"), flag(4, "D")]

        XCTAssertEqual(FlagPalette.merged(base: base, mine: [flag(1, "A2"), flag(2, "B"), flag(3, "C")],
                                          theirs: theirs).map(\.slot),
                       ["cabal-flag-03", "cabal-flag-01", "cabal-flag-02", "cabal-flag-04"],
                       "a rename is not a reorder: the row's order stands")
        XCTAssertEqual(FlagPalette.merged(base: base, mine: [flag(2, "B"), flag(1, "A"), flag(3, "C")],
                                          theirs: theirs).map(\.slot),
                       ["cabal-flag-02", "cabal-flag-01", "cabal-flag-03", "cabal-flag-04"])
    }

    func testTheSystemFlagsEntryIsMergedAsAnyOther() {
        let system = FlagPaletteEntry(slot: FlagPalette.systemSlot, label: "Today", color: "orange")
        let merged = FlagPalette.merged(base: [], mine: [flag(1, "Mine")], theirs: [system])

        XCTAssertEqual(merged, [system, flag(1, "Mine")])
    }

    // MARK: - The ledger

    private func ledger(holding app: [String: String], version: Int?) -> SettingsSyncLedger {
        var ledger = SettingsSyncLedger()
        _ = ledger.rebase(onto: SyncedSettingsRow(app: app, version: version), values: app, stored: Set(app.keys))
        return ledger
    }

    func testAnOwedKeyTheRowAlreadyHoldsAtThatValueIsSettled() {
        // A push whose first copy landed and whose second was refused: the
        // row the refusal answers already holds what this device sent.
        var ledger = ledger(holding: ["theme": "dark"], version: 1)
        ledger.edited(["theme"], values: ["theme": "light"])

        let apply = ledger.rebase(onto: SyncedSettingsRow(app: ["theme": "light"], version: 2),
                                  values: ["theme": "light"], stored: ["theme"])

        XCTAssertFalse(ledger.hasUnsent)
        XCTAssertEqual(apply, [:], "an owed key is not applied")
        XCTAssertEqual(ledger.version, 2)
    }

    func testTheFlagListIsComparedAsAListNotAsText() {
        // The server stores the list in its own spelling.
        let mine = #"[{"slot":"cabal-flag-01","label":"Later","color":"blue"}]"#
        let theirs = #"[{"color":"blue","label":"Later","slot":"cabal-flag-01"}]"#
        var ledger = ledger(holding: ["flag_palette": "[]"], version: 1)
        ledger.edited(["flag_palette"], values: ["flag_palette": mine])
        ledger.took(["flag_palette": mine], version: 2, values: ["flag_palette": mine])
        XCTAssertFalse(ledger.hasUnsent)

        let apply = ledger.rebase(onto: SyncedSettingsRow(app: ["flag_palette": theirs], version: 2),
                                  values: ["flag_palette": mine], stored: ["flag_palette"])

        XCTAssertEqual(apply, ["flag_palette": theirs])
        XCTAssertFalse(ledger.hasUnsent)
        ledger.edited(["flag_palette"], values: ["flag_palette": mine])
        XCTAssertFalse(ledger.hasUnsent, "the same list in another spelling is no change")
    }

    func testAServerThatAnswersNoVersionIsNeverOlder() {
        var ledger = ledger(holding: ["theme": "dark"], version: 3)

        XCTAssertTrue(ledger.isOlder(SyncedSettingsRow(app: [:], version: 2)))
        XCTAssertFalse(ledger.isOlder(SyncedSettingsRow(app: [:], version: 3)))
        XCTAssertFalse(ledger.isOlder(SyncedSettingsRow(app: [:], version: nil)))
        ledger.took([:], version: nil, values: [:])
        XCTAssertFalse(ledger.isOlder(SyncedSettingsRow(app: [:], version: 1)))
    }

    func testItSurvivesTheStore() throws {
        var ledger = ledger(holding: ["theme": "dark"], version: 3)
        ledger.edited(["signature"], values: ["theme": "dark", "signature": "x"])

        let data = try JSONEncoder().encode(ledger)

        XCTAssertEqual(try JSONDecoder().decode(SettingsSyncLedger.self, from: data), ledger)
    }
}
