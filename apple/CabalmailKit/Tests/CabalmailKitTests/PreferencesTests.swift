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
        ])
        let preferences = Preferences(store: store)
        XCTAssertEqual(preferences.markAsRead, .afterDelay)
        XCTAssertEqual(preferences.loadRemoteContent, .always)
        XCTAssertEqual(preferences.defaultFromAddress, "alice@example.com")
        XCTAssertEqual(preferences.signature, "Best,\nAlice")
        XCTAssertEqual(preferences.disposeAction, .trash)
        XCTAssertEqual(preferences.theme, .light)
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
}
