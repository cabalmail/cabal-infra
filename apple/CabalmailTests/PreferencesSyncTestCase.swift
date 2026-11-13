import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the `PreferencesSyncCoordinator` suites share: a client from the
/// app's own factory over `FakeSettingsServer`, which holds the `app` map,
/// refuses a map with a value stage refuses, and refuses a flag add its
/// palette does not list, as stage does; an account's settings as a launch
/// loads them; and coordinators that stop at the end of each test.
///
/// Most tests use a debounce too long to fire and make the debounced push
/// themselves (`pushUnsent()`), so they know when it has ended; the tests
/// that name the debounce set a short one.
@MainActor
class PreferencesSyncTestCase: XCTestCase {
    var root: URL!
    var server: FakeSettingsServer!
    var client: CabalmailClient!
    var store: InMemoryPreferenceStore!
    private var coordinators: [PreferencesSyncCoordinator] = []

    let newFlag = FlagPaletteEntry(slot: "cabal-flag-01", label: "Later", color: "blue")
    let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1", dataStoreUuid: "ds1",
                                       feed: RssFeedSummary(feedId: "f1", title: "F1"))
    let item = RssItem(feedId: "f1", itemId: "i1", sortKey: "2026-01-02T00:00:00+00:00#i001",
                       publishedAt: "2026-01-02T00:00:00+00:00")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefs-sync-retry-\(UUID().uuidString)")
        // The account already syncs a flag list, as the stage test account
        // does: an empty one.
        server = FakeSettingsServer(app: ["flag_palette": "[]", "theme": "system"])
        client = try CabalmailClient.make(
            configuration: TestFixtures.makeConfiguration(),
            secureStore: InMemorySecureStore(),
            httpTransport: server.transport,
            cacheDirectory: root
        )
        let auth = try XCTUnwrap(client.authService as? CognitoAuthService)
        try await auth.adopt(tokens: AuthTokens(
            idToken: "ID", accessToken: "ACCESS", refreshToken: "REFRESH",
            expiresAt: Date().addingTimeInterval(3600)
        ))
        store = InMemoryPreferenceStore()
    }

    override func tearDown() async throws {
        coordinators.forEach { $0.stop() }
        coordinators = []
        await client.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    /// The account's settings as a launch loads them: a new `Preferences`
    /// over the same store each time, so a second call is a relaunch.
    func launchPreferences(username: String = "alice") -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: "cabalmail.example", username: username)
        return preferences
    }

    /// A coordinator whose connection is `connection` (by default one that
    /// never changes), not the host's.
    func coordinator(
        _ preferences: Preferences,
        connection: AsyncStream<Bool> = AsyncStream { _ in },
        debounce: Duration = .seconds(3600)
    ) -> PreferencesSyncCoordinator {
        let sync = PreferencesSyncCoordinator(
            client: client, preferences: preferences, connection: connection, saveDebounce: debounce
        )
        coordinators.append(sync)
        return sync
    }

    /// The flag added in Settings > Flags while the settings push fails.
    func addFlagWhileThePushFails(_ preferences: Preferences, _ sync: PreferencesSyncCoordinator) async {
        await server.fail(.setPreferences)
        preferences.flagPalette = [newFlag]
        let sent = await sync.pushUnsent()
        XCTAssertFalse(sent, "the push failed")
        XCTAssertTrue(preferences.hasUnsentChanges)
    }

    func calls() async -> [String] {
        await server.calls.map(\.description)
    }

    /// The client's feed engine and store, holding one item of one feed.
    func feedItemOnTheDevice() async throws -> (RssSyncEngine, RssStore) {
        let engine = try XCTUnwrap(client.rssSync)
        let rssStore = try XCTUnwrap(client.rssStore)
        try await rssStore.upsertSubscription(subscription)
        try await rssStore.upsertItems([item])
        return (engine, rssStore)
    }
}
