import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A settings map the server refuses (#2439). `set_preferences` answers 400
/// for the whole map when one value breaks its rules, and the same map would
/// be refused again, so the coordinator does not send it again at every
/// trigger. It stays unsent and the pull stays held, so nothing the user
/// changed is lost; the next settings change sends again, and so does the
/// next launch, once. And the values a user can type are held to the
/// server's rules, so none of them gets there.
@MainActor
final class PreferencesSyncRefusalTests: PreferencesSyncTestCase {
    /// A thumbs-up with a skin tone: one character, two code points.
    private let thumbsUp = "\u{1F44D}\u{1F3FD}"

    private func refusedEdit(_ preferences: Preferences, _ sync: PreferencesSyncCoordinator) async {
        await server.refuseSettings()
        preferences.theme = .dark
        let sent = await sync.pushUnsent()
        XCTAssertFalse(sent, "refused")
        XCTAssertTrue(preferences.hasUnsentChanges)
    }

    // MARK: - Not sent again

    /// Before, the foreground, the connection's return and the feed queue's
    /// question each sent the same map again, and each was refused.
    func testARefusedMapIsNotSentAgainByTheTriggersAndHoldsThePull() async throws {
        let (connection, link) = AsyncStream.makeStream(of: Bool.self)
        link.yield(true)
        let preferences = launchPreferences()
        let sync = coordinator(preferences, connection: connection)
        await sync.start()
        await refusedEdit(preferences, sync)

        await sync.reconcile()
        let answer = await sync.sendUnsentForFeedQueue()
        link.yield(false)
        link.yield(true)
        // Room for the connection's return to send, which it must not.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(answer, .stillUnsent)
        let seen = await calls()
        XCTAssertEqual(seen, ["/get_preferences accepted", "/set_preferences refused"],
                       "no second push, and no pull over the unsent change")
        XCTAssertTrue(preferences.hasUnsentChanges)
        XCTAssertEqual(preferences.theme, .dark)
    }

    func testTheNextSettingsChangeSendsAgain() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await refusedEdit(preferences, sync)
        await server.refuseSettings(false)

        preferences.disposeAction = .trash
        let sent = await sync.pushUnsent()

        XCTAssertTrue(sent)
        XCTAssertFalse(preferences.hasUnsentChanges)
        let app = await server.app
        XCTAssertEqual(app["theme"], "dark")
        XCTAssertEqual(app["dispose_action"], "trash")
    }

    /// An offline failure is not a refusal: it still goes again at each
    /// trigger.
    func testAFailureThatIsNotARefusalStillGoesAgain() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.fail(.setPreferences)
        preferences.theme = .dark
        let failed = await sync.pushUnsent()
        XCTAssertFalse(failed)
        await server.reconnect()

        await sync.reconcile()

        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.offline, .accepted])
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// What the server refused is remembered for the session alone: the
    /// next launch sends once more, and holds its pull while it is refused.
    func testTheNextLaunchSendsOnceMoreAndHoldsThePullWhileItIsRefused() async throws {
        let first = launchPreferences()
        let firstSync = coordinator(first)
        await firstSync.start()
        await refusedEdit(first, firstSync)
        firstSync.stop()
        let before = await server.calls.count

        let relaunched = launchPreferences()
        let sync = coordinator(relaunched)
        await sync.start()
        await sync.reconcile()

        let seen = Array(await calls().dropFirst(before))
        XCTAssertEqual(seen, ["/set_preferences refused"])
        XCTAssertTrue(relaunched.hasUnsentChanges)
        XCTAssertEqual(relaunched.theme, .dark)
    }

    // MARK: - Values the server would refuse never go

    /// Before, the name was cut at 32 characters, which is 40 code points
    /// here, and the server refused the map.
    func testAnEmojiFlagNameIsTaken() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()

        preferences.flagPalette = [
            FlagPaletteEntry(slot: newFlag.slot, label: String(repeating: thumbsUp, count: 20), color: "blue"),
        ]
        let sent = await sync.pushUnsent()

        XCTAssertTrue(sent)
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
    }

    /// Before, the signature field had no cap.
    func testALongSignatureIsTaken() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()

        preferences.signature = String(repeating: "Regards\r\n", count: 300)
        let sent = await sync.pushUnsent()

        XCTAssertTrue(sent)
        let signature = await server.app["signature"]
        XCTAssertEqual(signature?.unicodeScalars.count, 2000)
    }

    /// 1.52.0 could store a flag with an empty name, and the server
    /// refused every map that carried it. The next launch names it, and
    /// its push is taken.
    func testAnEmptyNameAnOlderBuildStoredDoesNotStopTheSync() async throws {
        let older = launchPreferences()
        let scope = try XCTUnwrap(older.accountScope)
        let key = "\(Preferences.Key.flagPalette.rawValue).\(scope)"
        store.setString(#"[{"color":"blue","label":"","slot":"cabal-flag-01"}]"#, forKey: key)
        older.hasUnsentChanges = true

        let launched = launchPreferences()
        let sync = coordinator(launched)
        await sync.start()

        let seen = await calls()
        XCTAssertEqual(seen, ["/set_preferences accepted", "/get_preferences accepted"])
        XCTAssertFalse(launched.hasUnsentChanges)
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
    }
}
