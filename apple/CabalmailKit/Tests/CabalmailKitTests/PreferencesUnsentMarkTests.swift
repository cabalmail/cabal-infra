import XCTest
@testable import CabalmailKit

/// `Preferences.hasUnsentChanges`, the mark that a settings change has not
/// reached the server (#2421), which the session's sync coordinator keeps
/// so the change survives a relaunch.
@MainActor
final class PreferencesUnsentMarkTests: XCTestCase {
    private static let domain = "cabal.example.com"

    private func scopedKey(_ key: Preferences.Key, username: String = "chris") throws -> String {
        let scope = try XCTUnwrap(Preferences.scopeIdentifier(controlDomain: Self.domain, username: username))
        return "\(key.rawValue).\(scope)"
    }

    private func makeActivated(store: InMemoryPreferenceStore, username: String = "chris") -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: Self.domain, username: username)
        return preferences
    }

    /// The mark that a change has not reached the server lives in the
    /// store under the account's scope, so a relaunch (a new `Preferences`
    /// on the same store) still sees it and another account never does.
    /// It is sync state: never sent, never a local edit.
    func testTheUnsentMarkIsKeptPerAccountAndIsNotASetting() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store, username: "chris")
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.hasUnsentChanges = true

        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.unsentChanges)), "1")
        XCTAssertEqual(localChangeCount, 0, "the mark is not an edit to push")
        XCTAssertFalse(preferences.appPreferencesPayload().keys.contains { $0.contains("unsent") })
        XCTAssertTrue(makeActivated(store: store, username: "chris").hasUnsentChanges,
                      "a relaunch reads it back")

        preferences.activate(controlDomain: Self.domain, username: "apple")
        XCTAssertFalse(preferences.hasUnsentChanges, "another account has its own")
        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertTrue(preferences.hasUnsentChanges)

        preferences.hasUnsentChanges = false
        XCTAssertNil(store.stringValue(forKey: try scopedKey(.unsentChanges)))
        XCTAssertFalse(Preferences(store: store).hasUnsentChanges, "no account active, no mark")
    }
}
