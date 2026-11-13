import XCTest
@testable import CabalmailKit

/// The five keys the payload sends only once they are syncable
/// (`flag_palette`, `rss_mark_as_read`, the all-feeds filter and order, the
/// swipe set) keep that across a relaunch when the account's store holds a
/// value for them (#2437). Before, each gate started a launch closed, so a
/// change the last session could not send that put the setting back to its
/// default was left out of the launch's push, and the pull put the server's
/// value back: deleting the last flag of your own undid itself.
@MainActor
final class PreferencesSyncableAfterReloadTests: XCTestCase {
    private var store: InMemoryPreferenceStore!

    override func setUp() {
        store = InMemoryPreferenceStore()
    }

    /// The account's settings as a launch loads them; a second call over
    /// the same store is a relaunch.
    private func launch(_ username: String = "alice") -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: "cabalmail.example", username: username)
        return preferences
    }

    private let flag = FlagPaletteEntry(slot: "cabal-flag-01", label: "Later", color: "blue")

    // MARK: - Put back to the default by the user

    func testAnEmptiedPaletteStillRidesAfterARelaunch() {
        let first = launch()
        first.flagPalette = [flag]
        first.flagPalette = []

        XCTAssertEqual(launch().appPreferencesPayload()["flag_palette"], "[]")
    }

    func testFeedMarkAsReadPutBackStillRidesAfterARelaunch() {
        let first = launch()
        first.rssMarkAsRead = .onOpen
        first.rssMarkAsRead = .manual

        XCTAssertEqual(launch().appPreferencesPayload()["rss_mark_as_read"], "manual")
    }

    func testAllFeedsFilterPutBackStillRidesAfterARelaunch() {
        let first = launch()
        first.rssAllFeedsFilter = .all
        first.rssAllFeedsFilter = .defaultForFeeds

        XCTAssertEqual(launch().appPreferencesPayload()["filter:feeds:all"], RssItemFilter.defaultForFeeds.rawValue)
    }

    func testAllFeedsOrderPutBackStillRidesAfterARelaunch() {
        let first = launch()
        first.rssAllFeedsOrdering = .oldestFirst
        first.rssAllFeedsOrdering = .newestFirst

        XCTAssertEqual(launch().appPreferencesPayload()["order:feeds:all"], RssOrderingMode.newestFirst.rawValue)
    }

    func testSwipeBindingsPutBackStillRideAfterARelaunch() {
        let first = launch()
        first.rssSwipeTrailing = .toggleRead
        first.rssSwipeTrailing = .toggleFavorite

        let payload = launch().appPreferencesPayload()
        XCTAssertEqual(payload["swipe_leading"], "toggle_read")
        XCTAssertEqual(payload["swipe_trailing"], "dispose")
        XCTAssertEqual(payload["rss_swipe_leading"], "toggle_read")
        XCTAssertEqual(payload["rss_swipe_trailing"], "toggle_favorite")
    }

    // MARK: - Written by a pull

    /// A pull that carried the keys at their defaults proved the server
    /// knows them; the next launch still sends them.
    func testKeysAPullWroteStillRideAfterARelaunch() {
        launch().applyRemote([
            "flag_palette": "[]", "rss_mark_as_read": "manual", "rss_swipe_leading": "toggle_read",
        ])

        let payload = launch().appPreferencesPayload()
        XCTAssertEqual(payload["flag_palette"], "[]")
        XCTAssertEqual(payload["rss_mark_as_read"], "manual")
        XCTAssertEqual(payload["rss_swipe_leading"], "toggle_read")
    }

    // MARK: - Still closed

    /// Nothing stored, nothing sent: a launch with no value for a key still
    /// leaves it out, as for a server that may predate it. The store is per
    /// account, so another account's values open nothing here.
    func testAnotherAccountsStoredValuesOpenNoGate() {
        let alice = launch()
        alice.flagPalette = [flag]
        alice.flagPalette = []
        alice.rssMarkAsRead = .onOpen
        alice.rssAllFeedsFilter = .all
        alice.rssAllFeedsOrdering = .oldestFirst
        alice.swipeLeading = .toggleFlag

        let payload = launch("bob").appPreferencesPayload()
        for key in ["flag_palette", "rss_mark_as_read", "filter:feeds:all", "order:feeds:all", "swipe_leading"] {
            XCTAssertNil(payload[key], key)
        }
    }
}
