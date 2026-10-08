import CabalmailKit
import CabalmailShared
import XCTest

/// The handoff to the Notification Service Extensions, which read it through
/// CabalmailShared rather than the Kit. Nothing fails at run time when a name
/// or the token's shape drifts: every notification just shows "New mail"
/// again. So these pin today's values and check that what
/// `PushEnrichmentStore` writes reads back the way `NotificationService.swift`
/// reads it. (The App Group and the keychain group are also literals in the
/// entitlements files, which no test reads.)
final class PushHandoffContractTests: XCTestCase {
    func testSharedNamesKeepTheirShippedValues() {
        XCTAssertEqual(AppGroup.identifier, "group.com.cabalmail.Cabalmail")
        XCTAssertEqual(PushHandoff.keychainAccessGroupSuffix, "com.cabalmail.shared")
        XCTAssertEqual(PushHandoff.apiURLDefaultsKey, "cabal.push.api_url")
        XCTAssertEqual(PushHandoff.keychainService, "com.cabalmail.push")
        XCTAssertEqual(PushHandoff.keychainAccount, "push.auth")

        // The Kit's public names agree with the shared ones.
        XCTAssertEqual(PushEnrichmentStore.appGroupID, AppGroup.identifier)
        XCTAssertEqual(PushEnrichmentStore.keychainAccessGroupSuffix, PushHandoff.keychainAccessGroupSuffix)
        XCTAssertEqual(PushEnrichmentStore.apiURLDefaultsKey, PushHandoff.apiURLDefaultsKey)
        XCTAssertEqual(PushEnrichmentStore.keychainService, PushHandoff.keychainService)
        XCTAssertEqual(PushEnrichmentStore.keychainAccount, PushHandoff.keychainAccount)
    }

    /// The bytes a keychain item already holds: an app update must not strand
    /// a token an earlier build mirrored.
    func testTokenPayloadReadsTheShippedJSON() throws {
        let stored = Data(#"{"id_token":"id-1","expires_at":1000}"#.utf8)
        let payload = try JSONDecoder().decode(PushTokenPayload.self, from: stored)
        XCTAssertEqual(payload, PushTokenPayload(
            idToken: "id-1",
            expiresAt: Date(timeIntervalSinceReferenceDate: 1_000)
        ))

        let encoded = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["expires_at"] as? Double, 1_000)
    }

    func testTokenWrittenThroughTheStoreDecodesAsTheExtensionReadsIt() throws {
        let shared = InMemorySecureStore()
        let store = PushEnrichmentStore(secureStore: shared, defaults: nil)
        let expiry = Date(timeIntervalSinceReferenceDate: 812_345_678)
        store.updateToken(idToken: "id-1", expiresAt: expiry)

        let data = try XCTUnwrap(shared.get(PushHandoff.keychainAccount))
        // A plain decoder, as the extension's `currentIdToken()` uses.
        let payload = try JSONDecoder().decode(PushTokenPayload.self, from: data)
        XCTAssertEqual(payload, PushTokenPayload(idToken: "id-1", expiresAt: expiry))
    }

    func testAPIURLWrittenThroughTheStoreReadsBackFromTheSharedKey() throws {
        let suiteName = "PushHandoffContractTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = PushEnrichmentStore(secureStore: nil, defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://api.example.com/stage"))

        store.updateAPIURL(url)
        XCTAssertEqual(defaults.string(forKey: PushHandoff.apiURLDefaultsKey), url.absoluteString)

        store.clear()
        XCTAssertNil(defaults.string(forKey: PushHandoff.apiURLDefaultsKey))
    }
}
