import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A settings change the server has not taken (#2421): `PreferencesSyncCoordinator`
/// sends it again on return to the foreground, when the connection comes
/// back, at the next session's start (before the pull that would overwrite
/// it), and when the feed queue asks before dropping a flag add the server
/// refused. Against a client from the app's own factory over
/// `FakeSettingsServer`, which holds the `app` map and refuses a flag add
/// its palette does not list, as stage does.
///
/// Most tests use a debounce too long to fire and make the debounced push
/// themselves (`pushUnsent()`), so they know when it has ended;
/// `testAnEditIsPushedOnItsOwn` covers the debounce.
@MainActor
final class PreferencesSyncRetryTests: XCTestCase {
    private var root: URL!
    private var server: FakeSettingsServer!
    private var client: CabalmailClient!
    private var store: InMemoryPreferenceStore!
    private var coordinators: [PreferencesSyncCoordinator] = []

    private let newFlag = FlagPaletteEntry(slot: "cabal-flag-01", label: "Later", color: "blue")
    private let subscription = RssSubscription(subscriptionId: "s1", feedId: "f1", dataStoreUuid: "ds1",
                                               feed: RssFeedSummary(feedId: "f1", title: "F1"))
    private let item = RssItem(feedId: "f1", itemId: "i1", sortKey: "2026-01-02T00:00:00+00:00#i001",
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
    private func launchPreferences(username: String = "alice") -> Preferences {
        let preferences = Preferences(store: store)
        preferences.activate(controlDomain: "cabalmail.example", username: username)
        return preferences
    }

    /// A coordinator whose connection is `connection` (by default one that
    /// never changes), not the host's.
    private func coordinator(
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
    private func addFlagWhileThePushFails(_ preferences: Preferences, _ sync: PreferencesSyncCoordinator) async {
        await server.fail(.setPreferences)
        preferences.flagPalette = [newFlag]
        let sent = await sync.pushUnsent()
        XCTAssertFalse(sent, "the push failed")
        XCTAssertTrue(preferences.hasUnsentChanges)
    }

    private func calls() async -> [String] {
        await server.calls.map(\.description)
    }

    // MARK: - The debounce

    func testAnEditIsPushedOnItsOwn() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences, debounce: .milliseconds(10))
        await sync.start()
        let server = self.server!

        preferences.flagPalette = [newFlag]

        try await waitUntilOnMainActor { await server.paletteSlots == [newFlag.slot] }
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    // MARK: - Sent again

    /// Before: `reconcile` skipped while an edit was unsent, and sent
    /// nothing, so the flag waited for the next settings edit.
    func testAFailedPushGoesAgainOnReturnToTheForeground() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await addFlagWhileThePushFails(preferences, sync)
        await server.reconnect()

        await sync.reconcile()

        let seen = await calls()
        XCTAssertEqual(seen, ["/get_preferences accepted", "/set_preferences offline",
                              "/set_preferences accepted", "/get_preferences accepted"],
                       "the unsent change went first, then the pull")
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
        XCTAssertFalse(preferences.hasUnsentChanges)
        XCTAssertEqual(preferences.flagPalette, [newFlag])
    }

    func testAFailedPushGoesAgainWhenTheConnectionReturns() async throws {
        let (connection, link) = AsyncStream.makeStream(of: Bool.self)
        link.yield(true)
        let preferences = launchPreferences()
        let sync = coordinator(preferences, connection: connection)
        await sync.start()
        await addFlagWhileThePushFails(preferences, sync)
        await server.reconnect()

        link.yield(false)
        link.yield(true)

        let server = self.server!
        try await waitUntilOnMainActor { await server.paletteSlots == [newFlag.slot] }
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    // MARK: - Across a relaunch

    /// Before: the unsent mark lived in the coordinator, the next launch
    /// pulled first, and the server's empty list replaced the new flag.
    func testAnUnsentChangeOutlivesTheSessionAndGoesBeforeThePull() async throws {
        let first = launchPreferences()
        let firstSync = coordinator(first)
        await firstSync.start()
        await addFlagWhileThePushFails(first, firstSync)
        firstSync.stop()
        await server.reconnect()

        let relaunched = launchPreferences()
        XCTAssertTrue(relaunched.hasUnsentChanges, "the mark outlived the session")
        XCTAssertEqual(relaunched.flagPalette, [newFlag])
        let sync = coordinator(relaunched)
        await sync.start()

        let seen = await calls()
        XCTAssertEqual(Array(seen.suffix(2)), ["/set_preferences accepted", "/get_preferences accepted"])
        XCTAssertEqual(relaunched.flagPalette, [newFlag], "the pull did not put the server's older list over it")
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
        XCTAssertFalse(relaunched.hasUnsentChanges)
    }

    /// A launch whose own push fails does not pull, and the connection's
    /// first value (the connection as it is) is not a return: one attempt,
    /// until the connection really comes back.
    func testAFailedPushAtStartHoldsThePull() async throws {
        let preferences = launchPreferences()
        preferences.flagPalette = [newFlag]
        preferences.hasUnsentChanges = true
        await server.fail(.setPreferences)
        let (connection, link) = AsyncStream.makeStream(of: Bool.self)
        link.yield(true)
        let sync = coordinator(preferences, connection: connection)

        await sync.start()
        try await Task.sleep(for: .milliseconds(300))

        let seen = await calls()
        XCTAssertEqual(seen, ["/set_preferences offline"], "no pull, and no second attempt for the first value")
        XCTAssertEqual(preferences.flagPalette, [newFlag])

        await server.reconnect()
        link.yield(false)
        link.yield(true)
        let server = self.server!
        try await waitUntilOnMainActor { await server.paletteSlots == [newFlag.slot] }
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// The push of a session that has ended answers into nothing: by then
    /// the store's active scope may be another account's, whose own mark
    /// must stand. The next account holds the same settings, so nothing
    /// but the session's end tells the two apart.
    func testAPushStillOutWhenTheSessionEndsLeavesTheNextAccountsMark() async throws {
        launchPreferences(username: "bob").flagPalette = [newFlag]
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.holdNext(.setPreferences)
        preferences.flagPalette = [newFlag]
        let pushing = Task { await sync.pushUnsent() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.setPreferences) }

        sync.stop()
        preferences.activate(controlDomain: "cabalmail.example", username: "bob")
        preferences.hasUnsentChanges = true
        await server.release(.setPreferences)
        let sent = await pushing.value

        XCTAssertFalse(sent)
        XCTAssertTrue(preferences.hasUnsentChanges, "the next account's mark stands")
    }

    /// A push carries the settings as they were when it left: an edit made
    /// while it was out is still unsent when it lands.
    func testAnEditMadeWhileAPushWasOutStaysUnsent() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.holdNext(.setPreferences)
        preferences.flagPalette = [newFlag]
        let pushing = Task { await sync.pushUnsent() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.setPreferences) }

        preferences.theme = .dark
        await server.release(.setPreferences)
        let sent = await pushing.value

        XCTAssertFalse(sent)
        XCTAssertTrue(preferences.hasUnsentChanges, "the theme has not gone")
        let theme = await server.app["theme"]
        XCTAssertEqual(theme, "system")
        await sync.reconcile()
        let after = await server.app["theme"]
        XCTAssertEqual(after, "dark")
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// Before, a pull out while the user edited applied the server's copy
    /// over the edit.
    func testAPullDoesNotLandOverAnEditMadeWhileItWasOut() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.holdNext(.getPreferences)
        let reconciling = Task { await sync.reconcile() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.getPreferences) }

        preferences.flagPalette = [newFlag]
        await server.release(.getPreferences)
        await reconciling.value

        XCTAssertEqual(preferences.flagPalette, [newFlag])
        XCTAssertTrue(preferences.hasUnsentChanges)
    }

    // MARK: - The feed queue (the issue's steps)

    /// #2421 as filed: a flag created while the settings push fails, put
    /// on a feed item while the item's push fails too, then the connection
    /// back and the list refreshed. The server refuses the add, since it
    /// has not been told of the flag; the queue asks for the settings,
    /// they go, and the add goes again and is taken. Before, the add was
    /// dropped and the item lost the flag with no message.
    func testAFeedItemKeepsAFlagCreatedWhileTheSettingsPushFailed() async throws {
        let (engine, rssStore) = try await feedItemOnTheDevice()
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.fail(.setItemState)
        await addFlagWhileThePushFails(preferences, sync)
        try await engine.setFlag(item, slot: newFlag.slot, true)
        let before = await server.calls.count
        await server.reconnect()

        try await engine.drainPending()

        let seen = Array(await calls().dropFirst(before))
        XCTAssertEqual(seen, ["/rss_set_item_state refused", "/set_preferences accepted",
                              "/rss_set_item_state accepted"])
        let added = await server.acceptedFlagAdds
        XCTAssertEqual(added, [[newFlag.slot]])
        let flags = try await rssStore.item(feedId: item.feedId, sortKey: item.sortKey)?.flags
        XCTAssertEqual(flags, [newFlag.slot], "the item keeps its flag")
        let queued = try await rssStore.pendingCount()
        XCTAssertEqual(queued, 0)
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// The control: once the session's coordinator has stopped, nothing
    /// answers the queue, and the refused add is dropped as for a deleted
    /// flag.
    func testWithTheSessionEndedTheRefusedAddIsDropped() async throws {
        let (engine, rssStore) = try await feedItemOnTheDevice()
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.fail(.setItemState)
        await addFlagWhileThePushFails(preferences, sync)
        try await engine.setFlag(item, slot: newFlag.slot, true)
        sync.stop()
        await server.reconnect()

        try await engine.drainPending()

        let flags = try await rssStore.item(feedId: item.feedId, sortKey: item.sortKey)?.flags
        XCTAssertEqual(flags, [], "dropped, as for a deleted flag")
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.offline], "nothing asked for the settings")
    }

    /// The client's feed engine and store, holding one item of one feed.
    private func feedItemOnTheDevice() async throws -> (RssSyncEngine, RssStore) {
        let engine = try XCTUnwrap(client.rssSync)
        let rssStore = try XCTUnwrap(client.rssStore)
        try await rssStore.upsertSubscription(subscription)
        try await rssStore.upsertItems([item])
        return (engine, rssStore)
    }
}
