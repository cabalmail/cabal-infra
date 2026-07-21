import XCTest
@testable import CabalmailKit

/// `Preferences.reconcileDefaultFromAddress(available:)` — clearing a
/// default From address the account can't actually send from. Split from
/// `PreferencesTests` for the SwiftLint type-body cap.
@MainActor
final class PreferencesReconcileTests: XCTestCase {
    private static let domain = "cabal.example.com"

    private func makeActivated(
        store: InMemoryPreferenceStore? = nil
    ) -> Preferences {
        let preferences = Preferences(store: store ?? InMemoryPreferenceStore())
        preferences.activate(controlDomain: Self.domain, username: "chris")
        return preferences
    }

    private func scopedDefaultFromKey() throws -> String {
        let scope = try XCTUnwrap(Preferences.scopeIdentifier(
            controlDomain: Self.domain, username: "chris"
        ))
        return "\(Preferences.Key.defaultFromAddress.rawValue).\(scope)"
    }

    /// A default From that isn't in the account's address list — revoked, or
    /// leaked in from another account before per-account scoping — is cleared,
    /// and the clear fires `onLocalChange` so the sync coordinator pushes it
    /// to the server and heals the synced copy that keeps re-applying it.
    func testClearsDanglingDefaultFromAndFiresOnLocalChange() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)
        preferences.defaultFromAddress = "apple@testsubdomain.example.com"
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.reconcileDefaultFromAddress(
            available: ["mine@sub.example.com", "other@sub.example.com"]
        )

        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertNil(store.stringValue(forKey: try scopedDefaultFromKey()))
        XCTAssertEqual(localChangeCount, 1)
    }

    func testKeepsDefaultFromThatIsInTheList() {
        let preferences = makeActivated()
        preferences.defaultFromAddress = "mine@sub.example.com"
        preferences.reconcileDefaultFromAddress(
            available: ["mine@sub.example.com", "other@sub.example.com"]
        )
        XCTAssertEqual(preferences.defaultFromAddress, "mine@sub.example.com")
    }

    /// An empty list is inconclusive (a transient fetch hiccup), not proof
    /// the default is dangling — nothing is cleared.
    func testTreatsEmptyListAsInconclusive() {
        let preferences = makeActivated()
        preferences.defaultFromAddress = "mine@sub.example.com"
        preferences.reconcileDefaultFromAddress(available: [])
        XCTAssertEqual(preferences.defaultFromAddress, "mine@sub.example.com")
    }

    func testNoDefaultIsANoOp() {
        let preferences = makeActivated()
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }
        preferences.reconcileDefaultFromAddress(available: ["mine@sub.example.com"])
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertEqual(localChangeCount, 0)
    }
}
