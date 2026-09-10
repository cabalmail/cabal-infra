import XCTest
@testable import CabalmailKit

/// The feed reader's mark-as-read preference rides the synced `app` map
/// under its own key, gated the way `flag_palette` is: never pushed to a
/// server that has not shown it accepts the key.
@MainActor
final class PreferencesRssTests: XCTestCase {
    private func makePreferences() -> Preferences {
        let prefs = Preferences(store: InMemoryPreferenceStore())
        prefs.activate(controlDomain: "cabalmail.example", username: "alice")
        return prefs
    }

    func testDefaultIsManualAndNotSentUntilKnown() {
        let prefs = makePreferences()
        XCTAssertEqual(prefs.rssMarkAsRead, .manual)
        XCTAssertNil(prefs.appPreferencesPayload()["rss_mark_as_read"])
    }

    func testUserChangeMakesItRide() {
        let prefs = makePreferences()
        prefs.rssMarkAsRead = .onOpen
        XCTAssertEqual(prefs.appPreferencesPayload()["rss_mark_as_read"], "on_open")
        prefs.rssMarkAsRead = .manual
        XCTAssertEqual(prefs.appPreferencesPayload()["rss_mark_as_read"], "manual")
    }

    func testRemoteValueAppliesAndMakesItRide() {
        let prefs = makePreferences()
        prefs.applyRemote(["rss_mark_as_read": "on_open"])
        XCTAssertEqual(prefs.rssMarkAsRead, .onOpen)
        XCTAssertEqual(prefs.appPreferencesPayload()["rss_mark_as_read"], "on_open")
        // Mail's own key is untouched by the feed one.
        XCTAssertEqual(prefs.markAsRead, .manual)
    }

    func testUnknownRemoteValueLeavesCurrent() {
        let prefs = makePreferences()
        prefs.rssMarkAsRead = .onOpen
        prefs.applyRemote(["rss_mark_as_read": "after_a_while"])
        XCTAssertEqual(prefs.rssMarkAsRead, .onOpen)
    }
}
