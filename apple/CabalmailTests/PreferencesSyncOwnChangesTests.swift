import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A device sends only what was changed on it, and says which version of
/// the account's row it was built on. Before, every push carried the whole
/// settings map at this device's values, so a device that had never read
/// the row (#2452), or had not seen another device's change (#2464), put
/// its own copy over the account's. These are those issues' steps, and the
/// narrower windows beside them (#2441, #2451).
@MainActor
final class PreferencesSyncOwnChangesTests: PreferencesSyncTestCase {
    /// An account another device has set up: every one of these is a value
    /// a whole-map push from a new device would have reset.
    private let accountsSettings = [
        "signature": "The account's signature",
        "default_from_address": "me@mail.cabalmail.example",
        "mark_as_read": "on_open",
        "load_remote_content": "always",
        "dispose_action": "trash",
        "theme": "dark",
        "flag_palette": #"[{"color":"red","label":"Urgent","slot":"cabal-flag-02"}]"#,
    ]

    private func labels(on server: FakeSettingsServer) async -> [String] {
        let raw = await server.app["flag_palette"] ?? "[]"
        return (FlagPalette.decode(raw) ?? []).map(\.label)
    }

    // MARK: - #2452: a device that has not read the row

    /// The issue's steps: a device new to the account, the session's first
    /// pull fails, and a folder's Unread pill is tapped before any pull
    /// succeeds. Before, that push emptied the account's signature and
    /// Default From and put nine more settings back to their defaults.
    func testADeviceNewToTheAccountNeverSendsItsDefaults() async throws {
        await server.anotherDeviceWrites(accountsSettings)
        let onTheServer = await server.app
        await server.fail(.getPreferences)
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()

        preferences.setMailFolderFilter(.unread, for: "INBOX")
        let sentBeforeThePull = await sync.pushUnsent()

        XCTAssertFalse(sentBeforeThePull, "nothing goes before the row is read")
        let pushes = await server.calls(to: .setPreferences)
        XCTAssertEqual(pushes, [])
        XCTAssertTrue(preferences.hasUnsentChanges, "the tap is not lost")

        await server.reconnect()
        await sync.reconcile()

        let maps = await server.sentMaps
        XCTAssertEqual(maps, [["filter:mail:INBOX": "unread"]], "one push, of the one key")
        let after = await server.app
        XCTAssertEqual(after, onTheServer.merging(["filter:mail:INBOX": "unread"]) { _, new in new })
        XCTAssertEqual(preferences.signature, "The account's signature")
        XCTAssertEqual(preferences.defaultFromAddress, "me@mail.cabalmail.example")
        XCTAssertEqual(preferences.disposeAction, .trash)
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    // MARK: - #2464: a device that stayed in front

    /// The issue's steps: device B has the account's settings and stays in
    /// front; device A renames a flag; B taps a folder's Unread pill.
    /// Before, B's push carried its whole flag list and the rename was
    /// gone from the server.
    func testADeviceThatStayedInFrontDoesNotPutItsOlderSettingsBack() async throws {
        await server.anotherDeviceWrites(accountsSettings)
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        XCTAssertEqual(preferences.flagPalette.map(\.label), ["Urgent"])
        await server.anotherDeviceWrites([
            "flag_palette": #"[{"color":"red","label":"XD","slot":"cabal-flag-02"}]"#,
            "signature": "Changed on A",
        ])

        preferences.setMailFolderFilter(.unread, for: "INBOX")
        let sent = await sync.pushUnsent()

        XCTAssertTrue(sent)
        let onTheServer = await labels(on: server)
        XCTAssertEqual(onTheServer, ["XD"], "A's rename stands")
        let app = await server.app
        XCTAssertEqual(app["signature"], "Changed on A")
        XCTAssertEqual(app["filter:mail:INBOX"], "unread")
        // The server refused the push built on the older row, B took the
        // row it was answered with, and sent again on that.
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.stale, .accepted])
        let maps = await server.sentMaps
        XCTAssertEqual(maps, [["filter:mail:INBOX": "unread"], ["filter:mail:INBOX": "unread"]],
                       "never more than the pill")
        // And B has A's changes without waiting for its next foreground.
        XCTAssertEqual(preferences.flagPalette.map(\.label), ["XD"])
        XCTAssertEqual(preferences.signature, "Changed on A")
    }

    /// The same device then edits the flag list itself, on its older copy.
    /// The list is one value on the wire: before, the later write of it won
    /// whole, and A's new flag read to the server as deleted.
    func testBothDevicesEditTheFlagListAndBothEditsSurvive() async throws {
        await server.anotherDeviceWrites(accountsSettings)
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.anotherDeviceWrites(["flag_palette": #"""
        [{"color":"red","label":"Urgent","slot":"cabal-flag-02"},\#
        {"color":"teal","label":"Added on A","slot":"cabal-flag-03"}]
        """#])

        preferences.flagPalette += [newFlag]
        let sent = await sync.pushUnsent()

        XCTAssertTrue(sent)
        let onTheServer = await labels(on: server)
        XCTAssertEqual(onTheServer, ["Urgent", "Added on A", "Later"])
        XCTAssertEqual(preferences.flagPalette.map(\.label), ["Urgent", "Added on A", "Later"])
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// Another device that writes again and again between this one's
    /// answers does not keep it sending for ever: the push gives up, and
    /// the change waits for the next trigger.
    func testAPushGivesUpWhenTheRowKeepsMovingAndTheChangeWaits() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.keepsMovingOn()

        preferences.theme = .dark
        let sent = await sync.pushUnsent()

        XCTAssertFalse(sent)
        XCTAssertTrue(preferences.hasUnsentChanges, "the change is still owed")
        XCTAssertEqual(preferences.theme, .dark)
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.stale, .stale, .stale, .stale])
    }

    // MARK: - #2441: around the session's first pull

    /// An edit made while the session's first pull is out. Before, the
    /// edit observer was attached only after that pull, so the edit was
    /// never marked unsent, and the pull's answer replaced it.
    func testAnEditMadeWhileTheSessionsFirstPullIsOutIsSent() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await server.holdNext(.getPreferences)
        let starting = Task { await sync.start() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.getPreferences) }

        preferences.flagPalette = [newFlag]
        await server.release(.getPreferences)
        await starting.value

        XCTAssertEqual(preferences.flagPalette, [newFlag], "the pull's answer did not replace it")
        let slots = await server.paletteSlots
        XCTAssertEqual(slots, [newFlag.slot])
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// A pull that read the row before an edit's push and arrives after
    /// that push was answered. Before, it was applied (nothing was unsent
    /// by then) and the device showed the older value again, which its
    /// next push of anything sent back to the server.
    func testAPullAnswerOvertakenByAPushIsDropped() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.holdNextAnswer(.getPreferences)
        let reconciling = Task { await sync.reconcile() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.getPreferences) }

        preferences.theme = .dark
        let sent = await sync.pushUnsent()
        XCTAssertTrue(sent)
        await server.release(.getPreferences)
        await reconciling.value

        XCTAssertEqual(preferences.theme, .dark, "the older answer was dropped")
        XCTAssertFalse(preferences.hasUnsentChanges)
        let theme = await server.app["theme"]
        XCTAssertEqual(theme, "dark")
    }

    /// The feed queue asks about unsent settings after the server refused
    /// a flag add. A flag list that landed between the refusal and the
    /// question left nothing unsent, so before, the answer was "nothing
    /// unsent" and the queue dropped the add, though the flag was on the
    /// server by then.
    func testTheFeedQueueIsToldOfAFlagListThatHasJustLanded() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        let untouched = await sync.sendUnsentForFeedQueue()
        XCTAssertEqual(untouched, .nothingUnsent)
        preferences.theme = .dark
        await sync.pushUnsent()
        let afterAnotherSetting = await sync.sendUnsentForFeedQueue()
        XCTAssertEqual(afterAnotherSetting, .nothingUnsent, "only a flag list counts")

        preferences.flagPalette = [newFlag]
        await sync.pushUnsent()
        let answer = await sync.sendUnsentForFeedQueue()

        XCTAssertEqual(answer, .sent)
    }

    // MARK: - #2451: what a refusal or a change back used to leave

    /// Offline, a setting changed and changed back. Before, the unsent
    /// mark stayed set, and the reconnect sent this device's whole map,
    /// over whatever another device had changed meanwhile.
    func testASettingPutBackSendsNothing() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.fail(.setPreferences)
        preferences.theme = .dark
        await sync.pushUnsent()
        XCTAssertTrue(preferences.hasUnsentChanges)

        preferences.theme = .system
        await server.reconnect()
        await server.anotherDeviceWrites(["signature": "Changed elsewhere"])
        await sync.reconcile()

        XCTAssertFalse(preferences.hasUnsentChanges)
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.offline], "nothing was left to send")
        let signature = await server.app["signature"]
        XCTAssertEqual(signature, "Changed elsewhere")
    }

    /// An edit made while a push is out, when that push ends refused.
    /// Before, the push task sent again only after a request the server
    /// took, so the edit waited for another trigger though the settings
    /// were no longer the refused ones.
    func testAnEditMadeWhileARefusedPushWasOutGetsItsOwnRequest() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()
        await server.refuseNextSettings()
        await server.holdNext(.setPreferences)
        preferences.theme = .dark
        let pushing = Task { await sync.pushUnsent() }
        let server = self.server!
        try await waitUntilOnMainActor { await server.isHolding(.setPreferences) }

        preferences.disposeAction = .trash
        await server.release(.setPreferences)
        let sent = await pushing.value

        XCTAssertTrue(sent)
        let pushes = await server.calls(to: .setPreferences).map(\.outcome)
        XCTAssertEqual(pushes, [.refused, .accepted])
        let app = await server.app
        XCTAssertEqual(app["dispose_action"], "trash")
        XCTAssertEqual(app["theme"], "dark")
    }

    // MARK: - A server that predates the version

    /// Against a server that neither answers nor checks a version, a push
    /// still carries only the changed key, and names no version.
    func testAnOlderServerStillGetsOnlyTheChangedKey() async throws {
        await server.predatesTheVersion()
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()

        preferences.theme = .dark
        let sent = await sync.pushUnsent()
        preferences.setMailFolderFilter(.unread, for: "INBOX")
        let sentAgain = await sync.pushUnsent()

        XCTAssertTrue(sent)
        XCTAssertTrue(sentAgain)
        let maps = await server.sentMaps
        XCTAssertEqual(maps, [["theme": "dark"], ["filter:mail:INBOX": "unread"]])
        let versions = await server.sentVersions
        XCTAssertEqual(versions, [nil, nil])
        XCTAssertFalse(preferences.hasUnsentChanges)
    }

    /// With a server that does, every push names the version this device
    /// last saw, and takes the next one from the answer.
    func testEveryPushNamesTheVersionItWasBuiltOn() async throws {
        let preferences = launchPreferences()
        let sync = coordinator(preferences)
        await sync.start()

        preferences.theme = .dark
        await sync.pushUnsent()
        preferences.theme = .light
        await sync.pushUnsent()

        let versions = await server.sentVersions
        XCTAssertEqual(versions, [1, 2])
        XCTAssertEqual(preferences.settingsVersion, 3)
    }
}
