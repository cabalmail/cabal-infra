import XCTest
@testable import CabalmailKit

/// What `Preferences` owes the server and what it takes from it
/// (`Preferences+Sync.swift`): a user's edit owes the keys it changed and
/// no others, and the account's row is taken for every key that is not
/// owed. Whole-map pushes are what #2452 and #2464 describe; these hold
/// the per-key rule that replaces them.
@MainActor
final class PreferencesUnsentKeysTests: XCTestCase {
    private static let domain = "cabal.example.com"
    private let later = FlagPaletteEntry(slot: "cabal-flag-01", label: "Later", color: "blue")

    private func scopedKey(_ key: Preferences.Key, username: String = "chris") throws -> String {
        let scope = try XCTUnwrap(Preferences.scopeIdentifier(controlDomain: Self.domain, username: username))
        return "\(key.rawValue).\(scope)"
    }

    private func makeActivated(store: InMemoryPreferenceStore, username: String = "chris") -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: Self.domain, username: username)
        return preferences
    }

    /// The account's row as another device left it.
    private let accountsRow = SyncedSettingsRow(app: [
        "signature": "The account's signature",
        "default_from_address": "me@mail.example.com",
        "theme": "dark",
        "mark_as_read": "on_open",
        "flag_palette": #"[{"color":"red","label":"Urgent","slot":"cabal-flag-02"}]"#,
        "filter:mail:INBOX": "all",
    ], version: 4)

    // MARK: - What an edit owes

    func testAnEditOwesTheKeyItChangedAndNoOther() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        XCTAssertFalse(preferences.hasUnsentChanges)

        preferences.theme = .dark

        XCTAssertTrue(preferences.hasUnsentChanges)
        XCTAssertEqual(preferences.unsentChanges(), ["theme": "dark"])
        preferences.setMailFolderFilter(.unread, for: "INBOX")
        XCTAssertEqual(preferences.unsentChanges(), ["theme": "dark", "filter:mail:INBOX": "unread"])
    }

    func testSettingAValueToWhatItAlreadyIsOwesNothing() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        var notified = 0
        preferences.onLocalChange = { notified += 1 }

        preferences.theme = .system
        preferences.rssMarkAsRead = .manual

        XCTAssertGreaterThan(notified, 0, "the assignments did reach the persistence hook")
        XCTAssertFalse(preferences.hasUnsentChanges)
        XCTAssertEqual(preferences.unsentChanges(), [:])
    }

    /// Changing one swipe opens the gate the four swipe keys share, so all
    /// four enter the payload; only the one the user changed is owed. The
    /// other three are this device's defaults, not the account's choices.
    func testAGateThatOpensOwesOnlyTheValueTheUserChanged() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())

        preferences.swipeLeading = .dispose

        XCTAssertEqual(Set(preferences.appPreferencesPayload().keys).intersection(
            ["swipe_leading", "swipe_trailing", "rss_swipe_leading", "rss_swipe_trailing"]
        ).count, 4, "the gate opened for all four")
        XCTAssertEqual(preferences.unsentChanges(), ["swipe_leading": "dispose"])
    }

    /// What is owed lives in the store under the account's scope, so a
    /// relaunch (a new `Preferences` on the same store) still owes it and
    /// another account never does. It is sync state: never sent.
    func testWhatIsOwedIsKeptPerAccountAndAcrossARelaunch() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store, username: "chris")

        preferences.signature = "Mine"

        XCTAssertNotNil(store.stringValue(forKey: try scopedKey(.syncLedger)))
        XCTAssertFalse(preferences.appPreferencesPayload().keys.contains { $0.contains("ledger") })
        XCTAssertEqual(makeActivated(store: store, username: "chris").unsentChanges(), ["signature": "Mine"],
                       "a relaunch reads it back")

        preferences.activate(controlDomain: Self.domain, username: "apple")
        XCTAssertFalse(preferences.hasUnsentChanges, "another account has its own")
        XCTAssertEqual(preferences.unsentChanges(), [:])
        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertEqual(preferences.unsentChanges(), ["signature": "Mine"])

        let signedOut = Preferences(store: store)
        signedOut.theme = .dark
        XCTAssertFalse(signedOut.hasUnsentChanges, "no account active, nothing owed")
    }

    // MARK: - Taking the account's row

    /// #2452: a device new to the account holds defaults. Whatever the
    /// user changes before the row is read, the rest is the account's.
    func testADeviceNewToTheAccountOwesOnlyWhatWasChangedOnIt() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        XCTAssertFalse(preferences.hasSettingsRow)
        preferences.setMailFolderFilter(.unread, for: "INBOX")

        XCTAssertTrue(preferences.take(accountsRow))

        XCTAssertTrue(preferences.hasSettingsRow)
        XCTAssertEqual(preferences.settingsVersion, 4)
        XCTAssertEqual(preferences.unsentChanges(), ["filter:mail:INBOX": "unread"])
        XCTAssertEqual(preferences.signature, "The account's signature")
        XCTAssertEqual(preferences.defaultFromAddress, "me@mail.example.com")
        XCTAssertEqual(preferences.theme, .dark)
        XCTAssertEqual(preferences.markAsRead, .onOpen)
        XCTAssertEqual(preferences.flagPalette.map(\.slot), ["cabal-flag-02"])
        XCTAssertEqual(preferences.mailFolderFilter(for: "INBOX"), .unread, "the user's own change stays")
    }

    /// #2464: a device that has the row and stayed in front. Its pull, or
    /// the row a refused push is answered with, brings the other device's
    /// changes and leaves its own unsent one.
    func testTakingANewerRowKeepsThisDevicesUnsentKeyAndTakesTheRest() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        preferences.take(accountsRow)
        var notified = 0
        preferences.onLocalChange = { notified += 1 }
        preferences.setMailFolderFilter(.unread, for: "INBOX")
        notified = 0

        var newer = accountsRow
        newer.version = 5
        newer.app["signature"] = "Changed on the other device"
        newer.app["filter:mail:Archive"] = "flagged"
        preferences.take(newer)

        XCTAssertEqual(preferences.signature, "Changed on the other device")
        XCTAssertEqual(preferences.mailFolderFilter(for: "Archive"), .flagged)
        XCTAssertEqual(preferences.mailFolderFilter(for: "INBOX"), .unread)
        XCTAssertEqual(preferences.unsentChanges(), ["filter:mail:INBOX": "unread"])
        XCTAssertEqual(preferences.settingsVersion, 5)
        XCTAssertEqual(notified, 0, "what the server said is not an edit")
        // Nor is it compared with as one: the next edit owes its own key only.
        preferences.theme = .light
        XCTAssertEqual(Set(preferences.unsentChanges().keys), ["filter:mail:INBOX", "theme"])
    }

    /// Both devices changed the flag list. The list is one value on the
    /// wire, so the row's is merged with this device's instead of either
    /// replacing the other.
    func testAnOwedFlagListIsMergedWithTheRows() throws {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        preferences.take(accountsRow)
        preferences.flagPalette += [later]

        var newer = accountsRow
        newer.version = 5
        newer.app["flag_palette"] = #"""
        [{"color":"red","label":"Urgent","slot":"cabal-flag-02"},\#
        {"color":"teal","label":"Theirs","slot":"cabal-flag-03"}]
        """#
        preferences.take(newer)

        XCTAssertEqual(preferences.flagPalette.map(\.slot), ["cabal-flag-02", "cabal-flag-03", "cabal-flag-01"])
        let owed = try XCTUnwrap(preferences.unsentChanges()["flag_palette"].flatMap(FlagPalette.decode))
        XCTAssertEqual(owed.map(\.label), ["Urgent", "Theirs", "Later"], "the merged list is what goes")
    }

    func testARowOlderThanTheOneHeldIsNotTaken() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        var newer = accountsRow
        newer.version = 5
        newer.app["signature"] = "Newer"
        preferences.take(newer)

        XCTAssertFalse(preferences.take(accountsRow), "an answer overtaken on its way")

        XCTAssertEqual(preferences.signature, "Newer")
        XCTAssertEqual(preferences.settingsVersion, 5)
    }

    // MARK: - Settling

    func testWhatTheServerTookIsNoLongerOwedUnlessItChangedSince() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        preferences.take(accountsRow)
        preferences.signature = "First"
        preferences.theme = .light
        let sent = preferences.unsentChanges()
        preferences.signature = "Second"

        preferences.settingsTaken(sent, version: 5)

        XCTAssertEqual(preferences.unsentChanges(), ["signature": "Second"])
        XCTAssertEqual(preferences.settingsVersion, 5)
    }

    /// #2451: a setting changed and changed back holds what the server
    /// holds. Nothing is owed, so no trigger sends this device's map.
    func testASettingPutBackToWhatTheServerHoldsIsNotOwed() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())
        preferences.take(accountsRow)

        preferences.theme = .light
        XCTAssertTrue(preferences.hasUnsentChanges)
        preferences.theme = .dark

        XCTAssertFalse(preferences.hasUnsentChanges)
        XCTAssertEqual(preferences.unsentChanges(), [:])
    }

    // MARK: - Values only this device holds

    /// A value stored here that the row has no key for is the only copy
    /// there is. Whole-map pushes sent it at the next edit of anything;
    /// it is owed when the row is read instead.
    func testAStoredValueTheRowLacksIsOwedOnceTheRowIsRead() throws {
        let store = InMemoryPreferenceStore()
        let before = makeActivated(store: store)
        before.flagPalette = [later]
        before.signature = "Mine"
        // As a build that kept no record of what it owed left the store.
        store.setSilently(nil, forKey: try scopedKey(.syncLedger))
        let preferences = makeActivated(store: store)
        XCTAssertFalse(preferences.hasUnsentChanges)

        preferences.take(SyncedSettingsRow(app: ["signature": "Theirs", "theme": "dark"], version: 2))

        XCTAssertEqual(Set(preferences.unsentChanges().keys), ["flag_palette"])
        XCTAssertEqual(preferences.signature, "Theirs", "a key the row holds is the row's")
        XCTAssertEqual(preferences.flagPalette, [later])
    }

    /// A device new to the account stores nothing, so it owes an empty row
    /// nothing: its defaults are not values.
    func testDefaultsAreNotOwedToARowThatLacksThem() {
        let preferences = makeActivated(store: InMemoryPreferenceStore())

        preferences.take(SyncedSettingsRow(app: [:], version: 0))

        XCTAssertTrue(preferences.hasSettingsRow)
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// Builds up to 1.53.0 marked "something is unsent" and no more. The
    /// first row read after the update turns that into the keys: whatever
    /// this device stores that differs from the row, which is what that
    /// build's push would have changed.
    func testThePreviousBuildsMarkOwesWhatDiffersFromTheRow() throws {
        let store = InMemoryPreferenceStore()
        let before = makeActivated(store: store)
        before.take(accountsRow)
        before.signature = "Changed while the push failed"
        store.setSilently(nil, forKey: try scopedKey(.syncLedger))
        store.setSilently("1", forKey: try scopedKey(.unsentChanges))
        let preferences = makeActivated(store: store)
        XCTAssertTrue(preferences.hasUnsentChanges, "the mark still counts before the row is read")
        XCTAssertEqual(preferences.unsentChanges(), [:], "though it does not say what")

        var newer = accountsRow
        newer.version = 5
        newer.app["theme"] = "light"
        preferences.take(newer)

        XCTAssertEqual(Set(preferences.unsentChanges().keys), ["signature", "theme"])
        XCTAssertEqual(preferences.signature, "Changed while the push failed")
        XCTAssertNil(store.stringValue(forKey: try scopedKey(.unsentChanges)), "the mark is spent")
    }

    // MARK: - Across an account switch

    /// #2452: the gates say which keys an account has synced. One
    /// `Preferences` object serves every account signed in during a run,
    /// and the gates the first opened must not put its keys in the
    /// second's payload.
    func testASecondAccountDoesNotInheritTheFirstAccountsOpenGates() {
        let preferences = makeActivated(store: InMemoryPreferenceStore(), username: "chris")
        preferences.flagPalette = [later]
        preferences.rssMarkAsRead = .onOpen
        preferences.rssAllFeedsFilter = .all
        preferences.rssAllFeedsOrdering = .oldestFirst
        preferences.swipeLeading = .dispose
        let gated: Set<String> = ["flag_palette", "rss_mark_as_read", "filter:feeds:all", "order:feeds:all",
                                  "swipe_leading", "swipe_trailing", "rss_swipe_leading", "rss_swipe_trailing"]
        XCTAssertTrue(gated.isSubset(of: preferences.appPreferencesPayload().keys))

        preferences.activate(controlDomain: Self.domain, username: "apple")

        XCTAssertTrue(gated.isDisjoint(with: preferences.appPreferencesPayload().keys))
        // And back: the first account's own gates open again from its store.
        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertTrue(gated.isSubset(of: preferences.appPreferencesPayload().keys))
    }
}
