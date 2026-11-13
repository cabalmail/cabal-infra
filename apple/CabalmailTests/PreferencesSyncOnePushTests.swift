import XCTest
import CabalmailKit
@testable import CabalmailUI

/// One settings push at a time (#2440, #2444): whoever asks for a push
/// while one is out waits on it; an edit made while it was out goes in
/// another as soon as it lands, even when that edit's own wait ended while
/// the first was out; and a session that has ended sends nothing. With the
/// feed queue's two questions the #2421 fix's tests left out: its answer
/// while the push still fails, and its hook in place before `start()`.
@MainActor
final class PreferencesSyncOnePushTests: PreferencesSyncTestCase {
    /// The push out, held by the server.
    private func pushHeld(_ sync: PreferencesSyncCoordinator) async throws -> Task<Bool, Never> {
        await server.holdNext(.setPreferences)
        let pushing = Task { await sync.pushUnsent() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.setPreferences) }
        return pushing
    }

    // MARK: - One at a time

    /// The foreground's reconcile and the feed queue's question can ask
    /// while the other's push is out; the second waits on the first.
    func testAPushAskedForWhileOneIsOutWaitsOnIt() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        preferences.flagPalette = [newFlag]
        let first = try await pushHeld(sync)

        let second = Task { await sync.sendUnsentForFeedQueue() }
        try await Task.sleep(for: .milliseconds(100))
        await server.release(.setPreferences)
        let sent = await first.value
        let answer = await second.value

        XCTAssertTrue(sent)
        XCTAssertEqual(answer, .sent)
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.accepted], "one request")
    }

    // MARK: - An edit made while a push is out (#2440)

    /// The issue's case: the edit's one-second wait (here 10 ms) ends while
    /// the push is still out, so it joins that push, which does not carry
    /// it. Before, it stayed unsent until another trigger.
    func testAnEditWhoseWaitEndsWhileAPushIsOutGoesWhenThatPushLands() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences, debounce: .milliseconds(10))
        await sync.start()
        await server.holdNext(.setPreferences)
        preferences.flagPalette = [newFlag]
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.setPreferences) }

        preferences.theme = .dark
        // Well past the edit's 10 ms wait: it has ended, and joined the
        // push that is out.
        try await Task.sleep(for: .milliseconds(300))
        await server.release(.setPreferences)

        try await waitUntilOnMainActor { !preferences.hasUnsentChanges }
        let theme = await server.app["theme"]
        XCTAssertEqual(theme, "dark")
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.accepted, .accepted])
    }

    /// A session that ends while its push is out sends nothing more when
    /// the push lands, even with an edit made meanwhile.
    func testASessionThatEndsWhileAPushIsOutSendsNoSecondPush() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        preferences.flagPalette = [newFlag]
        let pushing = try await pushHeld(sync)

        preferences.theme = .dark
        sync.stop()
        await server.release(.setPreferences)
        let sent = await pushing.value

        XCTAssertFalse(sent)
        let pushes = await server.calls(to: .setPreferences).count
        XCTAssertEqual(pushes, 1)
    }

    /// A push asked for just before a sign-in over the session (which stops
    /// the coordinator and activates the next account's settings) sends
    /// nothing: by the time it would take its map, the map is the next
    /// account's. Before, it took that map and sent it through the old
    /// session's client.
    func testAPushThatStartsAfterTheSessionEndedTakesNoSettings() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("needs Task.immediate") }
        launchPreferences(username: "bob").theme = .light
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        preferences.flagPalette = [newFlag]

        // `pushUnsent()` starts its push in a task of its own. Started
        // immediately, the call runs up to that task before this test goes
        // on, so the session ends between the two every time; a plain
        // `Task` and a yield leave the order to the scheduler.
        let pushing = Task.immediate { await sync.pushUnsent() }
        sync.stop()
        preferences.activate(controlDomain: "cabalmail.example", username: "bob")
        preferences.hasUnsentChanges = true
        let sent = await pushing.value

        XCTAssertFalse(sent)
        let pushes = await server.calls(to: .setPreferences).count
        XCTAssertEqual(pushes, 0, "bob's settings did not go through alice's session")
        XCTAssertTrue(preferences.hasUnsentChanges, "bob's mark stands")
    }

    // MARK: - The feed queue

    /// While the settings push still fails, the coordinator tells the feed
    /// queue so, and the queue keeps the refused add on its item rather than
    /// dropping it (#2444, item 2).
    func testWhileTheSettingsPushFailsTheFeedQueueKeepsTheAdd() async throws {
        let (engine, rssStore) = try await feedItemOnTheDevice()
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.fail(.setItemState)
        await addFlagWhileThePushFails(preferences, sync)
        try await engine.setFlag(item, slot: newFlag.slot, true)
        await server.fail(.setItemState, false)
        let before = await server.calls.count

        try await engine.drainPending()

        let seen = Array(await calls().dropFirst(before))
        XCTAssertEqual(seen, ["/rss_set_item_state refused", "/set_preferences offline"])
        let flags = try await rssStore.item(feedId: item.feedId, sortKey: item.sortKey)?.flags
        XCTAssertEqual(flags, [newFlag.slot], "the item keeps its flag")
        let queued = try await rssStore.pendingCount()
        XCTAssertEqual(queued, 1, "the add waits in the queue")
        XCTAssertTrue(preferences.hasUnsentChanges)
    }

    /// The hook is in place from the coordinator's init, so a drain that
    /// runs before `start()` (the app starts both side by side) already asks
    /// it (#2444, item 4). The flag came from a session that could not send
    /// it.
    func testTheFeedQueueAsksBeforeTheSessionHasStarted() async throws {
        let (engine, rssStore) = try await feedItemOnTheDevice()
        let preferences = launchPreferences()
        preferences.flagPalette = [newFlag]
        preferences.hasUnsentChanges = true
        _ = coordinator(preferences)
        try await engine.setFlag(item, slot: newFlag.slot, true)

        try await engine.drainPending()

        let seen = await calls()
        XCTAssertEqual(seen, ["/rss_set_item_state refused", "/set_preferences accepted",
                              "/rss_set_item_state accepted"])
        let flags = try await rssStore.item(feedId: item.feedId, sortKey: item.sortKey)?.flags
        XCTAssertEqual(flags, [newFlag.slot])
    }
}
