import XCTest
@testable import CabalmailKit

/// The configurable swipe bindings ride the synced `app` map as four keys,
/// gated like `rss_mark_as_read`: never pushed to a server that has not
/// shown it accepts them, and pushed as a set once one of them is known.
@MainActor
final class PreferencesSwipeTests: XCTestCase {
    private static let keys = ["swipe_leading", "swipe_trailing", "rss_swipe_leading", "rss_swipe_trailing"]

    private func makePreferences() -> Preferences {
        let prefs = Preferences(store: InMemoryPreferenceStore())
        prefs.activate(controlDomain: "cabalmail.example", username: "alice")
        return prefs
    }

    func testDefaultsAreTheHistoricalArrangementAndNotSentUntilKnown() {
        let prefs = makePreferences()
        XCTAssertEqual(prefs.swipeLeading, .toggleRead)
        XCTAssertEqual(prefs.swipeTrailing, .dispose)
        XCTAssertEqual(prefs.rssSwipeLeading, .toggleRead)
        XCTAssertEqual(prefs.rssSwipeTrailing, .toggleFavorite)
        let payload = prefs.appPreferencesPayload()
        for key in Self.keys {
            XCTAssertNil(payload[key], key)
        }
    }

    func testUserChangeMakesAllFourRide() {
        let prefs = makePreferences()
        prefs.swipeTrailing = .toggleFlag
        let payload = prefs.appPreferencesPayload()
        XCTAssertEqual(payload["swipe_leading"], "toggle_read")
        XCTAssertEqual(payload["swipe_trailing"], "toggle_flag")
        XCTAssertEqual(payload["rss_swipe_leading"], "toggle_read")
        XCTAssertEqual(payload["rss_swipe_trailing"], "toggle_favorite")
        // Reverting to the default keeps them riding: the choice syncs over
        // another device's earlier one.
        prefs.swipeTrailing = .dispose
        XCTAssertEqual(prefs.appPreferencesPayload()["swipe_trailing"], "dispose")
    }

    func testTheSameActionMayBindBothEdgesAndAnEdgeMayBeDisabled() {
        let prefs = makePreferences()
        prefs.swipeLeading = .toggleRead
        prefs.swipeTrailing = .toggleRead
        prefs.rssSwipeLeading = .disabled
        let payload = prefs.appPreferencesPayload()
        XCTAssertEqual(payload["swipe_leading"], "toggle_read")
        XCTAssertEqual(payload["swipe_trailing"], "toggle_read")
        XCTAssertEqual(payload["rss_swipe_leading"], "none")
    }

    func testRemoteValuesApplyAndMakeThemRide() {
        let prefs = makePreferences()
        prefs.applyRemote(["swipe_leading": "dispose", "rss_swipe_trailing": "none"])
        XCTAssertEqual(prefs.swipeLeading, .dispose)
        XCTAssertEqual(prefs.swipeTrailing, .dispose)
        XCTAssertEqual(prefs.rssSwipeTrailing, .disabled)
        XCTAssertEqual(prefs.appPreferencesPayload()["rss_swipe_leading"], "toggle_read")
    }

    func testValuesFromTheOtherListsVocabularyLeaveCurrent() {
        let prefs = makePreferences()
        prefs.swipeLeading = .toggleFlag
        prefs.applyRemote(["swipe_leading": "toggle_favorite", "rss_swipe_leading": "dispose"])
        XCTAssertEqual(prefs.swipeLeading, .toggleFlag)
        XCTAssertEqual(prefs.rssSwipeLeading, .toggleRead)
    }

    func testBindingsPersistAcrossReload() {
        let store = InMemoryPreferenceStore()
        let prefs = Preferences(store: store)
        prefs.activate(controlDomain: "cabalmail.example", username: "alice")
        prefs.swipeLeading = .disabled
        prefs.rssSwipeTrailing = .toggleRead
        let again = Preferences(store: store)
        again.activate(controlDomain: "cabalmail.example", username: "alice")
        XCTAssertEqual(again.swipeLeading, .disabled)
        XCTAssertEqual(again.rssSwipeTrailing, .toggleRead)
    }
}
