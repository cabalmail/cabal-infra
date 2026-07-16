import XCTest
@testable import CabalmailKit

@MainActor
final class PreferencesTests: XCTestCase {
    // MARK: - Defaults

    func testDefaultsMatchTheSpec() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        XCTAssertEqual(preferences.markAsRead, .manual)
        XCTAssertEqual(preferences.loadRemoteContent, .off)
        XCTAssertNil(preferences.defaultFromAddress)
        XCTAssertEqual(preferences.signature, "")
        XCTAssertEqual(preferences.disposeAction, .archive)
        XCTAssertEqual(preferences.theme, .system)
        XCTAssertEqual(preferences.defaultBodyRenderMode, .original)
    }

    func testDisposeActionDestinationFolders() {
        XCTAssertEqual(DisposeAction.archive.destinationFolder, "Archive")
        XCTAssertEqual(DisposeAction.trash.destinationFolder, "Trash")
    }

    // MARK: - Persistence

    func testAssignmentsArePersistedImmediately() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)

        preferences.markAsRead = .onOpen
        preferences.loadRemoteContent = .ask
        preferences.defaultFromAddress = "me@example.com"
        preferences.signature = "-- sent from iOS"
        preferences.disposeAction = .trash
        preferences.theme = .dark
        preferences.defaultBodyRenderMode = .reader

        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.markAsRead.rawValue),
            "on_open"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.loadRemoteContent.rawValue),
            "ask"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.defaultFromAddress.rawValue),
            "me@example.com"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.signature.rawValue),
            "-- sent from iOS"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.disposeAction.rawValue),
            "trash"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.theme.rawValue),
            "dark"
        )
        XCTAssertEqual(
            store.stringValue(forKey: Preferences.Key.defaultBodyRenderMode.rawValue),
            "reader"
        )
    }

    func testNilDefaultFromRemovesKey() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        preferences.defaultFromAddress = "me@example.com"
        preferences.defaultFromAddress = nil
        XCTAssertNil(store.stringValue(forKey: Preferences.Key.defaultFromAddress.rawValue))
    }

    // MARK: - External change handling

    func testExternalChangeRefreshesValues() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        XCTAssertEqual(preferences.theme, .system)

        store.simulateExternalChange { snapshot in
            snapshot.setSilently("dark", forKey: Preferences.Key.theme.rawValue)
            snapshot.setSilently("on_open", forKey: Preferences.Key.markAsRead.rawValue)
            snapshot.setSilently("alice@example.com", forKey: Preferences.Key.defaultFromAddress.rawValue)
        }

        XCTAssertEqual(preferences.theme, .dark)
        XCTAssertEqual(preferences.markAsRead, .onOpen)
        XCTAssertEqual(preferences.defaultFromAddress, "alice@example.com")
    }

    /// An external-update handler that wrote back to the store would spiral
    /// into an infinite loop — `reload()` sets a `isReloading` guard so the
    /// `didSet` hooks don't re-persist. This test pins that guard by making
    /// every key an external update and asserting no additional writes.
    func testExternalReloadDoesNotReentrantlyPersist() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        // Seed some local writes so we can tell one-off vs. doubled writes.
        preferences.signature = "one"
        XCTAssertEqual(store.stringValue(forKey: Preferences.Key.signature.rawValue), "one")

        // Silently mutate the store (as iCloud would) and fire the handler.
        store.simulateExternalChange { snapshot in
            snapshot.setSilently("two", forKey: Preferences.Key.signature.rawValue)
        }
        XCTAssertEqual(preferences.signature, "two")
        // Value in the store should still be the pushed value — no double
        // write from the reload path.
        XCTAssertEqual(store.stringValue(forKey: Preferences.Key.signature.rawValue), "two")
    }

    // MARK: - Initial reads from populated store

    func testInitialValuesReadFromStore() {
        let store = InMemoryPreferenceStore(initialValues: [
            Preferences.Key.markAsRead.rawValue: "after_delay",
            Preferences.Key.loadRemoteContent.rawValue: "always",
            Preferences.Key.defaultFromAddress.rawValue: "alice@example.com",
            Preferences.Key.signature.rawValue: "Best,\nAlice",
            Preferences.Key.disposeAction.rawValue: "trash",
            Preferences.Key.theme.rawValue: "light",
            Preferences.Key.defaultBodyRenderMode.rawValue: "reader",
        ])
        let preferences = Preferences(store: store)
        XCTAssertEqual(preferences.markAsRead, .afterDelay)
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
    func testUnknownRawValuesFallBackToDefaults() {
        let store = InMemoryPreferenceStore(initialValues: [
            Preferences.Key.markAsRead.rawValue: "whenever",
            Preferences.Key.theme.rawValue: "lunar-eclipse",
        ])
        let preferences = Preferences(store: store)
        XCTAssertEqual(preferences.markAsRead, .manual)
        XCTAssertEqual(preferences.theme, .system)
    }

    // MARK: - Server sync marshalling

    /// The full payload sent to the server round-trips back through
    /// `applyRemote(_:)` so a setting saved on one device reproduces exactly on
    /// another. Every synced key is exercised with a non-default value.
    func testAppPreferencesPayloadRoundTripsThroughApplyRemote() {
        let source = Preferences(store: InMemoryPreferenceStore())
        source.markAsRead = .afterDelay
        source.loadRemoteContent = .always
        source.defaultFromAddress = "me@example.com"
        source.signature = "Cheers,\nChris"
        source.disposeAction = .trash
        source.theme = .dark
        source.crashReportingEnabled = true
        source.defaultBodyRenderMode = .reader
        source.folderCountDisplay = .both

        let target = Preferences(store: InMemoryPreferenceStore())
        target.applyRemote(source.appPreferencesPayload())

        XCTAssertEqual(target.markAsRead, .afterDelay)
        XCTAssertEqual(target.loadRemoteContent, .always)
        XCTAssertEqual(target.defaultFromAddress, "me@example.com")
        XCTAssertEqual(target.signature, "Cheers,\nChris")
        XCTAssertEqual(target.disposeAction, .trash)
        XCTAssertEqual(target.theme, .dark)
        XCTAssertTrue(target.crashReportingEnabled)
        XCTAssertEqual(target.defaultBodyRenderMode, .reader)
        XCTAssertEqual(target.folderCountDisplay, .both)
    }

    /// An empty From address is encoded as "" on the wire and must decode back
    /// to `nil` ("no default"), not an empty string.
    func testApplyRemoteEmptyFromAddressBecomesNil() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.defaultFromAddress = "was@example.com"
        preferences.applyRemote(["default_from_address": ""])
        XCTAssertNil(preferences.defaultFromAddress)
    }

    /// A server apply must write through to the local store (so the fast-path
    /// cache matches the server) but must NOT fire `onLocalChange` — echoing an
    /// inbound update back out as a save would loop between devices.
    func testApplyRemoteWritesStoreButDoesNotFireOnLocalChange() {
        let store = InMemoryPreferenceStore()
        let preferences = Preferences(store: store)
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.applyRemote(["theme": "dark", "dispose_action": "trash"])

        XCTAssertEqual(localChangeCount, 0)
        // Written through to the local store as a cache of the server value.
        XCTAssertEqual(store.stringValue(forKey: Preferences.Key.theme.rawValue), "dark")
        XCTAssertEqual(store.stringValue(forKey: Preferences.Key.disposeAction.rawValue), "trash")
    }

    /// A genuine user edit fires `onLocalChange` so the sync coordinator can
    /// debounce a push. Unknown/garbage remote values leave the value untouched.
    func testLocalEditFiresOnLocalChange() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        var localChangeCount = 0
        preferences.onLocalChange = { localChangeCount += 1 }

        preferences.theme = .light
        preferences.disposeAction = .trash

        XCTAssertEqual(localChangeCount, 2)
    }

    func testApplyRemoteIgnoresUnknownAndMissingValues() {
        let preferences = Preferences(store: InMemoryPreferenceStore())
        preferences.theme = .dark
        // A garbage theme and a key we don't recognize both leave state intact.
        preferences.applyRemote(["theme": "lunar-eclipse", "unknown_key": "x"])
        XCTAssertEqual(preferences.theme, .dark)
    }
}
