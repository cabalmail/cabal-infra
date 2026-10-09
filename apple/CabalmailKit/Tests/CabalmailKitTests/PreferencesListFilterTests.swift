import XCTest
@testable import CabalmailKit

/// The sticky filter pills that ride the synced `app` map: one
/// `filter:mail:<folder>` key per mail folder, and `filter:feeds:all`
/// for the all-feeds list (gated like `rss_mark_as_read`, never pushed to a
/// server that has not shown it accepts the key).
@MainActor
final class PreferencesListFilterTests: XCTestCase {
    private func makePreferences(store: InMemoryPreferenceStore? = nil) -> Preferences {
        let prefs = Preferences(store: store ?? InMemoryPreferenceStore())
        prefs.activate(controlDomain: "cabalmail.example", username: "alice")
        return prefs
    }

    // MARK: - Mail folders

    func testFolderDefaultsToAllAndSendsNothing() {
        let prefs = makePreferences()
        XCTAssertEqual(prefs.mailFolderFilter(for: "INBOX"), .all)
        XCTAssertFalse(prefs.appPreferencesPayload().keys.contains { $0.hasPrefix("filter:mail:") })
    }

    func testSettingAFolderPillPersistsAndRidesAsItsOwnKey() throws {
        let store = InMemoryPreferenceStore()
        let prefs = makePreferences(store: store)
        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }

        prefs.setMailFolderFilter(.unread, for: "INBOX")
        prefs.setMailFolderFilter(.flagged, for: "Archive/2026")
        prefs.setMailFolderFilter(.unread, for: "INBOX") // no-op: already unread

        XCTAssertEqual(localChanges, 2)
        XCTAssertEqual(prefs.mailFolderFilter(for: "INBOX"), .unread)
        let payload = prefs.appPreferencesPayload()
        XCTAssertEqual(payload["filter:mail:INBOX"], "unread")
        XCTAssertEqual(payload["filter:mail:Archive/2026"], "flagged")
        // Stored locally as one JSON object under the account's key, and
        // read back the same way on reload.
        let key = try XCTUnwrap(prefs.storageKey(.mailFolderFilters))
        XCTAssertEqual(store.stringValue(forKey: key), #"{"Archive/2026":"flagged","INBOX":"unread"}"#)
        prefs.reload()
        XCTAssertEqual(prefs.mailFolderFilter(for: "Archive/2026"), .flagged)
    }

    func testChoosingAllIsStoredSoItSyncsOverAnEarlierChoice() {
        let prefs = makePreferences()
        prefs.setMailFolderFilter(.unread, for: "INBOX")
        prefs.setMailFolderFilter(.all, for: "INBOX")
        XCTAssertEqual(prefs.appPreferencesPayload()["filter:mail:INBOX"], "all")
    }

    func testRemoteFolderPillsMergePerFolderWithoutEchoing() {
        let prefs = makePreferences()
        var localChanges = 0
        prefs.onLocalChange = { localChanges += 1 }
        prefs.setMailFolderFilter(.flagged, for: "Local")
        localChanges = 0

        prefs.applyRemote([
            "filter:mail:INBOX": "unread",
            "filter:mail:Junk": "sometimes",   // unknown pill: dropped
            "filter:mail:": "all",             // empty path: dropped
            "theme": "dark",
        ])

        XCTAssertEqual(localChanges, 0)
        XCTAssertEqual(prefs.mailFolderFilter(for: "INBOX"), .unread)
        XCTAssertEqual(prefs.mailFolderFilter(for: "Local"), .flagged, "a folder the server lacks keeps its pill")
        XCTAssertEqual(prefs.mailFolderFilter(for: "Junk"), .all)
        XCTAssertEqual(prefs.mailFolderFilters.count, 2)
    }

    func testFolderFilterCodecRoundTripsAndTolerantlyDecodes() {
        let filters: [String: MessageFilter] = ["INBOX": .unread, "Sent Items": .flagged]
        XCTAssertEqual(Preferences.decodeFolderFilters(Preferences.encodeFolderFilters(filters)), filters)
        XCTAssertEqual(Preferences.decodeFolderFilters(nil), [:])
        XCTAssertEqual(Preferences.decodeFolderFilters("not json"), [:])
        XCTAssertEqual(Preferences.decodeFolderFilters(#"{"INBOX":"starred","Drafts":"all"}"#), ["Drafts": .all])
    }

    // MARK: - All feeds

    func testAllFeedsDefaultsToUnreadAndIsNotSentUntilKnown() {
        let prefs = makePreferences()
        XCTAssertEqual(prefs.rssAllFeedsFilter, .unread)
        XCTAssertNil(prefs.appPreferencesPayload()["filter:feeds:all"])
    }

    func testAllFeedsUserChangeMakesItRide() {
        let prefs = makePreferences()
        prefs.rssAllFeedsFilter = .favorite
        XCTAssertEqual(prefs.appPreferencesPayload()["filter:feeds:all"], "favorite")
        prefs.rssAllFeedsFilter = .unread
        XCTAssertEqual(prefs.appPreferencesPayload()["filter:feeds:all"], "unread")
    }

    func testAllFeedsRemoteValueAppliesAndMakesItRide() {
        let prefs = makePreferences()
        prefs.applyRemote(["filter:feeds:all": "all"])
        XCTAssertEqual(prefs.rssAllFeedsFilter, .all)
        XCTAssertEqual(prefs.appPreferencesPayload()["filter:feeds:all"], "all")
        prefs.applyRemote(["filter:feeds:all": "flagged"])
        XCTAssertEqual(prefs.rssAllFeedsFilter, .all, "the mail pill name is not a feed pill")
    }

    // MARK: - All feeds order

    func testAllFeedsOrderDefaultsToNewestFirstAndIsNotSentUntilKnown() {
        let prefs = makePreferences()
        XCTAssertEqual(prefs.rssAllFeedsOrdering, .newestFirst)
        XCTAssertNil(prefs.appPreferencesPayload()["order:feeds:all"],
                     "a server from before the key would 400 the whole map")
    }

    func testAllFeedsOrderUserChangeMakesItRide() {
        let prefs = makePreferences()
        prefs.rssAllFeedsOrdering = .oldestFirst
        XCTAssertEqual(prefs.appPreferencesPayload()["order:feeds:all"], "oldest_first")
        prefs.rssAllFeedsOrdering = .newestFirst
        XCTAssertEqual(prefs.appPreferencesPayload()["order:feeds:all"], "newest_first",
                       "choosing the default again still syncs over an earlier choice")
    }

    func testAllFeedsOrderRemoteValueAppliesAndMakesItRide() {
        let prefs = makePreferences()
        prefs.applyRemote(["order:feeds:all": "newest_day_oldest_within"])
        XCTAssertEqual(prefs.rssAllFeedsOrdering, .newestDayOldestWithin)
        XCTAssertEqual(prefs.appPreferencesPayload()["order:feeds:all"], "newest_day_oldest_within")
        prefs.applyRemote(["order:feeds:all": "oldest"])
        XCTAssertEqual(prefs.rssAllFeedsOrdering, .newestDayOldestWithin, "an unknown order is ignored")
    }
}
