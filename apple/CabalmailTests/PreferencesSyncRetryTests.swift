import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A settings change the server has not taken (#2421): `PreferencesSyncCoordinator`
/// sends it again on return to the foreground, when the connection comes
/// back, at the next session's start (before the pull that would overwrite
/// it), and when the feed queue asks before dropping a flag add the server
/// refused. The setup and helpers are `PreferencesSyncTestCase`'s;
/// `testAnEditIsPushedOnItsOwn` covers the debounce.
@MainActor
final class PreferencesSyncRetryTests: PreferencesSyncTestCase {
    // MARK: - The debounce

    func testAnEditIsPushedOnItsOwn() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences, debounce: .milliseconds(10))
        await sync.start()
        let server = self.server!

        preferences.flagPalette = [newFlag]

        // The client's mark, not the server's state: the server holds the
        // flag before the reply has come back to clear the mark (#2444).
        try await waitUntilOnMainActor { !preferences.hasUnsentChanges }
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
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

        try await waitUntilOnMainActor { !preferences.hasUnsentChanges }
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
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
        try await waitUntilOnMainActor { !preferences.hasUnsentChanges }
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
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

    /// A push carries the settings as they were when it left; an edit made
    /// while it was out goes in a second push as soon as it lands, and a
    /// caller waiting on the push gets the answer for both (#2440). Before,
    /// the push answered "still unsent" and nothing sent the edit until
    /// another trigger.
    func testAnEditMadeWhileAPushWasOutGoesInASecondPushWhenItLands() async throws {
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

        XCTAssertTrue(sent)
        XCTAssertFalse(preferences.hasUnsentChanges)
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.accepted, .accepted])
        let theme = await server.app["theme"]
        XCTAssertEqual(theme, "dark")
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
}
