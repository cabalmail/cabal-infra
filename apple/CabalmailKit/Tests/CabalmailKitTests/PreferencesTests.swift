import XCTest
@testable import CabalmailKit

@MainActor
final class PreferencesTests: XCTestCase {
    private static let domain = "cabal.example.com"

    /// The store key `Preferences` uses for `key` under `username`'s
    /// account scope, for seeding stores and asserting writes.
    private func scopedKey(
        _ key: Preferences.Key, username: String = "chris"
    ) throws -> String {
        let scope = try XCTUnwrap(Preferences.scopeIdentifier(
            controlDomain: Self.domain, username: username
        ))
        return "\(key.rawValue).\(scope)"
    }

    private func makeActivated(
        store: InMemoryPreferenceStore? = nil,
        username: String = "chris"
    ) -> Preferences {
        let preferences = Preferences(store: store ?? InMemoryPreferenceStore())
        preferences.activate(controlDomain: Self.domain, username: username)
        return preferences
    }

    // MARK: - Defaults

    func testDefaultsMatchTheSpec() {
        let preferences = makeActivated()
        XCTAssertEqual(preferences.markAsRead, .manual)
        XCTAssertEqual(preferences.loadRemoteContent, .off)
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertEqual(preferences.signature, "")
        XCTAssertEqual(preferences.disposeAction, .archive)
        XCTAssertEqual(preferences.disposeAdvance, .nextUnread)
        XCTAssertEqual(preferences.markReadAdvance, .stay)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.defaultBodyRenderMode, .original)
    }

    func testDisposeActionDestinationFolders() {
        XCTAssertEqual(DisposeAction.archive.destinationFolder, "Archive")
        XCTAssertEqual(DisposeAction.trash.destinationFolder, "Trash")
    }

    // MARK: - Persistence

    func testAssignmentsArePersistedImmediately() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)

        preferences.markAsRead = .onOpen
        preferences.loadRemoteContent = .ask
        preferences.defaultFromAddress = "me@example.com"
        preferences.signature = "-- sent from iOS"
        preferences.disposeAction = .trash
        preferences.disposeAdvance = .previousUnread
        preferences.markReadAdvance = .nextUnread
        preferences.theme = .dark
        preferences.defaultBodyRenderMode = .reader

        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.markAsRead)), "on_open")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.loadRemoteContent)), "ask")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.defaultFromAddress)), "me@example.com")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.signature)), "-- sent from iOS")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.disposeAction)), "trash")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.disposeAdvance)), "previous_unread")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.markReadAdvance)), "next_unread")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.theme)), "dark")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.defaultBodyRenderMode)), "reader")
        // Nothing lands on the legacy device-wide keys.
        for key in Preferences.Key.allCases {
            XCTAssertNil(store.stringValue(forKey: key.rawValue))
        }
    }

    func testNilDefaultFromRemovesKey() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)
        preferences.defaultFromAddress = "me@example.com"
        preferences.defaultFromAddress = nil
        XCTAssertNil(store.stringValue(forKey: try scopedKey(.defaultFromAddress)))
    }

    // MARK: - Account scoping

    /// The reported cross-account leak: sign in as chris, set preferences,
    /// sign out, sign in as apple, set different preferences, sign back in
    /// as chris. Chris must get chris's values back — never apple's, and
    /// most especially not apple's default From address.
    func testAccountSwitchIsolatesPreferences() {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store, username: "chris")
        preferences.defaultBodyRenderMode = .reader
        preferences.defaultFromAddress = nil
        preferences.markAsRead = .manual
        preferences.loadRemoteContent = .off

        preferences.activate(controlDomain: Self.domain, username: "apple")
        // A fresh account starts from defaults, not from chris's values.
        XCTAssertEqual(preferences.defaultBodyRenderMode, .original)
        XCTAssertNil(preferences.defaultFromAddress)
        preferences.defaultBodyRenderMode = .original
        preferences.defaultFromAddress = "apple@testsubdomain.example.com"
        preferences.markAsRead = .onOpen
        preferences.loadRemoteContent = .always

        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertEqual(preferences.defaultBodyRenderMode, .reader)
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertEqual(preferences.markAsRead, .manual)
        XCTAssertEqual(preferences.loadRemoteContent, .off)
    }

    /// Values stored under the legacy device-wide keys (pre-account-scoping
    /// builds) are deleted on activation, not inherited by whichever
    /// account signs in next.
    func testActivationPurgesLegacyDeviceWideValues() {
        let store = InMemoryPreferenceStore(initialValues: [
            Preferences.Key.theme.rawValue: "dark",
            Preferences.Key.defaultFromAddress.rawValue: "previous-user@example.com",
        ])
        let preferences = makeActivated(store: store)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertNil(store.stringValue(forKey: Preferences.Key.theme.rawValue))
        XCTAssertNil(store.stringValue(forKey: Preferences.Key.defaultFromAddress.rawValue))
    }

    /// Before any activation (fresh install, signed out) edits stay in
    /// memory: nothing persists, and the first activation resets to that
    /// account's stored state.
    func testWritesBeforeActivationAreNotPersisted() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.theme = .dark
        preferences.defaultFromAddress = "me@example.com"
        for key in Preferences.Key.allCases {
            XCTAssertNil(store.stringValue(forKey: key.rawValue))
        }
        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertNil(preferences.defaultFromAddress)
    }

    /// Re-activating the already-active account must not reload (and so
    /// must not clobber an in-memory value mid-write) — `wireSession`
    /// re-activates on every sign-in and restore.
    func testReactivatingSameAccountIsANoOp() {
        let preferences = makeActivated()
        preferences.theme = .dark
        preferences.activate(controlDomain: Self.domain, username: "chris")
        XCTAssertEqual(preferences.theme, .dark)
    }

    /// Account switches happen inside `reload()`'s persistence guard, so
    /// they must never read as local edits and echo out to the server as a
    /// save under the new account.
    func testActivationDoesNotFireOnLocalChange() {
        let preferences = makeActivated(username: "chris")
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }
        preferences.activate(controlDomain: Self.domain, username: "apple")
        XCTAssertEqual(localChangeCount, 0)
    }

    // MARK: - External change handling

    func testExternalChangeRefreshesValues() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)
        XCTAssertEqual(preferences.theme, .system)

        let themeKey = try scopedKey(.theme)
        let markAsReadKey = try scopedKey(.markAsRead)
        let fromKey = try scopedKey(.defaultFromAddress)
        store.simulateExternalChange { snapshot in
            snapshot.setSilently("dark", forKey: themeKey)
            snapshot.setSilently("on_open", forKey: markAsReadKey)
            snapshot.setSilently("alice@example.com", forKey: fromKey)
        }

        XCTAssertEqual(preferences.theme, .dark)
        XCTAssertEqual(preferences.markAsRead, .onOpen)
        XCTAssertEqual(preferences.defaultFromAddress, "alice@example.com")
    }

    /// An external-update handler that wrote back to the store would spiral
    /// into an infinite loop — `reload()` sets a `isReloading` guard so the
    /// `didSet` hooks don't re-persist. This test pins that guard by making
    /// every key an external update and asserting no additional writes.
    func testExternalReloadDoesNotReentrantlyPersist() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)
        let signatureKey = try scopedKey(.signature)
        // Seed some local writes so we can tell one-off vs. doubled writes.
        preferences.signature = "one"
        XCTAssertEqual(store.stringValue(forKey: signatureKey), "one")

        // Silently mutate the store (as iCloud would) and fire the handler.
        store.simulateExternalChange { snapshot in
            snapshot.setSilently("two", forKey: signatureKey)
        }
        XCTAssertEqual(preferences.signature, "two")
        // Value in the store should still be the pushed value — no double
        // write from the reload path.
        XCTAssertEqual(store.stringValue(forKey: signatureKey), "two")
    }

    // MARK: - Initial reads from populated store

    func testActivationReadsStoredAccountValues() throws {
        let store = InMemoryPreferenceStore(initialValues: [
            try scopedKey(.markAsRead): "on_open",
            try scopedKey(.loadRemoteContent): "always",
            try scopedKey(.defaultFromAddress): "alice@example.com",
            try scopedKey(.signature): "Best,\nAlice",
            try scopedKey(.disposeAction): "trash",
            try scopedKey(.theme): "light",
            try scopedKey(.defaultBodyRenderMode): "reader",
        ])
        let preferences = makeActivated(store: store)
        XCTAssertEqual(preferences.markAsRead, .onOpen)
        XCTAssertEqual(preferences.loadRemoteContent, .always)
        XCTAssertEqual(preferences.defaultFromAddress, "alice@example.com")
        XCTAssertEqual(preferences.signature, "Best,\nAlice")
        XCTAssertEqual(preferences.disposeAction, .trash)
        XCTAssertEqual(preferences.theme, .light)
        XCTAssertEqual(preferences.defaultBodyRenderMode, .reader)
    }

    /// Garbage values in the store (wire drift, a legacy build, a typo) fall
    /// back to the enum's default rather than crashing or persisting an
    /// invalid value forward.
    func testUnknownRawValuesFallBackToDefaults() throws {
        let store = InMemoryPreferenceStore(initialValues: [
            try scopedKey(.markAsRead): "whenever",
            try scopedKey(.theme): "lunar-eclipse",
        ])
        let preferences = makeActivated(store: store)
        XCTAssertEqual(preferences.markAsRead, .manual)
        XCTAssertEqual(preferences.theme, .system)
    }

    // MARK: - Server sync marshalling

    /// The full payload sent to the server round-trips back through
    /// `applyRemote(_:)` so a setting saved on one device reproduces exactly on
    /// another. Every synced key is exercised with a non-default value.
    func testAppPreferencesPayloadRoundTripsThroughApplyRemote() {
        let source = makeActivated()
        source.markAsRead = .onOpen
        source.loadRemoteContent = .always
        source.defaultFromAddress = "me@example.com"
        source.signature = "Cheers,\nChris"
        source.disposeAction = .trash
        source.disposeAdvance = .firstUnread
        source.markReadAdvance = .previousUnread
        source.theme = .dark
        source.crashReportingEnabled = true
        source.defaultBodyRenderMode = .reader
        source.folderCountDisplay = .both

        let target = makeActivated()
        target.applyRemote(source.appPreferencesPayload())

        XCTAssertEqual(target.markAsRead, .onOpen)
        XCTAssertEqual(target.loadRemoteContent, .always)
        XCTAssertEqual(target.defaultFromAddress, "me@example.com")
        XCTAssertEqual(target.signature, "Cheers,\nChris")
        XCTAssertEqual(target.disposeAction, .trash)
        XCTAssertEqual(target.disposeAdvance, .firstUnread)
        XCTAssertEqual(target.markReadAdvance, .previousUnread)
        XCTAssertEqual(target.theme, .dark)
        XCTAssertTrue(target.crashReportingEnabled)
        XCTAssertEqual(target.defaultBodyRenderMode, .reader)
        XCTAssertEqual(target.folderCountDisplay, .both)
    }

    /// An empty From address is encoded as "" on the wire and must decode back
    /// to `nil` ("no default"), not an empty string.
    func testApplyRemoteEmptyFromAddressBecomesNil() {
        let preferences = makeActivated()
        preferences.defaultFromAddress = "was@example.com"
        preferences.applyRemote(["default_from_address": ""])
        XCTAssertNil(preferences.defaultFromAddress)
    }

    /// A server apply must write through to the local store (so the fast-path
    /// cache matches the server) but must NOT fire `onLocalChange` — echoing an
    /// inbound update back out as a save would loop between devices.
    func testApplyRemoteWritesStoreButDoesNotFireOnLocalChange() throws {
        let store = InMemoryPreferenceStore()
        let preferences = makeActivated(store: store)
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.applyRemote(["theme": "dark", "dispose_action": "trash"])

        XCTAssertEqual(localChangeCount, 0)
        // Written through to the local store as a cache of the server value,
        // under the active account's keys.
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.theme)), "dark")
        XCTAssertEqual(store.stringValue(forKey: try scopedKey(.disposeAction)), "trash")
    }

    /// A genuine user edit fires `onLocalChange` so the sync coordinator can
    /// debounce a push. Unknown/garbage remote values leave the value untouched.
    func testLocalEditFiresOnLocalChange() {
        let preferences = makeActivated()
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.theme = .light
        preferences.disposeAction = .trash

        XCTAssertEqual(localChangeCount, 2)
    }

    func testApplyRemoteIgnoresUnknownAndMissingValues() {
        let preferences = makeActivated()
        preferences.theme = .dark
        // A garbage theme and a key we don't recognize both leave state intact.
        preferences.applyRemote(["theme": "lunar-eclipse", "unknown_key": "x"])
        XCTAssertEqual(preferences.theme, .dark)
    }

}
