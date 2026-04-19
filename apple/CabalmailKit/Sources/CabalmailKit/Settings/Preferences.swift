import Foundation
import Observation

// User-facing behavior toggles persisted across launches and — via
// `UbiquitousPreferenceStore` — synced between the user's devices through
// iCloud's key-value store.
//
// Phase 6 scope (`docs/0.6.0/ios-client-plan.md`) covers four surfaces:
// Reading (mark-as-read + remote-content gating), Composing (default From
// + signature), Actions (dispose swipe target), Appearance (theme).
//
// The `Preferences` class below is intentionally `@MainActor` +
// `@Observable` — SwiftUI views bind directly to its mutable properties,
// and read access happens synchronously on the main queue where every
// SwiftUI body already runs. A paired `PreferenceStore` abstraction keeps
// the storage side pluggable so tests can exercise external-change handling
// without reaching for the real iCloud key-value store.

// MARK: - Enums

/// How the reader marks a message read when the detail view opens.
///
/// Defaults to `.manual` per the plan — a behavior that matches the React
/// app, where the user always explicitly marks messages read via the swipe
/// action, toolbar button, or context menu. The `.afterDelay` case is a
/// plain 2-second wait mirroring Mail.app's equivalent option.
public enum MarkAsReadBehavior: String, Codable, Sendable, CaseIterable, Identifiable {
    case manual
    case onOpen = "on_open"
    case afterDelay = "after_delay"

    public var id: String { rawValue }
}

/// Policy for remote resource loading inside the HTML body renderer.
///
/// The renderer's `WKContentRuleList` blocks every non-`file://` request
/// unless the current message's `remoteContentAllowed` flag is on. This
/// preference controls the default value for that flag when a message view
/// first appears — Off leaves the user in control per-message; Always drops
/// the block entirely for users who don't care about tracker pixels.
public enum LoadRemoteContentPolicy: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case ask
    case always

    public var id: String { rawValue }
}

/// Controls the left-swipe / toolbar "dispose" action in the message list.
///
/// `archive` matches Mail.app's default; `trash` matches Gmail web's. The
/// React app hardcoded Archive, so `archive` is the default here too.
public enum DisposeAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case archive
    case trash

    public var id: String { rawValue }

    /// The IMAP folder name this action targets.
    public var destinationFolder: String {
        switch self {
        case .archive: return "Archive"
        case .trash:   return "Trash"
        }
    }
}

/// Theme override applied above the system setting.
public enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

// MARK: - Storage protocol

/// Minimal key/value surface `Preferences` needs from its backing store.
///
/// Production wires a `UbiquitousPreferenceStore` that writes to both
/// `UserDefaults` (for fast local reads) and `NSUbiquitousKeyValueStore`
/// (for cross-device sync via iCloud). Tests inject
/// `InMemoryPreferenceStore` and drive external-change semantics via
/// `simulateExternalChange(_:)`.
///
/// The protocol is `@MainActor`-bound so `Preferences` — also `@MainActor`
/// — can call into the store without actor hops. Strict concurrency on this
/// project is `complete`, so that isolation has to be explicit.
@MainActor
public protocol PreferenceStore: AnyObject {
    func stringValue(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)

    /// Registers the single external-change handler the store invokes when
    /// a value arrives from another device. The store retains the handler
    /// until `stopObserving()` or store deinit. Calling twice replaces the
    /// previous handler.
    func startObserving(_ handler: @escaping @MainActor () -> Void)
    func stopObserving()
}

// MARK: - Preferences

/// Observable preferences surface consumed by views and view models.
///
/// Persists to its `PreferenceStore` synchronously in each property's
/// `didSet`. External updates (e.g. an iCloud push from another device)
/// land through `reload()`, which sets `isReloading` to suppress the
/// persistence hooks while it rewrites stored state — preventing a local
/// write from bouncing the value right back to cloud and thrashing.
@Observable
@MainActor
public final class Preferences {
    /// Canonical keys for every stored preference. Rawvalues double as the
    /// on-disk key in `UserDefaults` and `NSUbiquitousKeyValueStore`, so
    /// these strings are load-bearing — don't rename without a migration.
    public enum Key: String, CaseIterable, Sendable {
        case markAsRead = "cabalmail.prefs.mark_as_read"
        case loadRemoteContent = "cabalmail.prefs.load_remote_content"
        case defaultFromAddress = "cabalmail.prefs.default_from_address"
        case signature = "cabalmail.prefs.signature"
        case disposeAction = "cabalmail.prefs.dispose_action"
        case theme = "cabalmail.prefs.theme"
    }

    public var markAsRead: MarkAsReadBehavior {
        didSet { persist(.markAsRead, markAsRead.rawValue) }
    }
    public var loadRemoteContent: LoadRemoteContentPolicy {
        didSet { persist(.loadRemoteContent, loadRemoteContent.rawValue) }
    }
    /// Default From address preselected in the compose sheet when the user
    /// has not otherwise chosen one. `nil` means "no default" — Send stays
    /// disabled until the user picks or creates an address.
    public var defaultFromAddress: String? {
        didSet { persist(.defaultFromAddress, defaultFromAddress) }
    }
    /// Plain-text signature appended to outgoing messages. Empty string
    /// means no signature.
    public var signature: String {
        didSet { persist(.signature, signature) }
    }
    public var disposeAction: DisposeAction {
        didSet { persist(.disposeAction, disposeAction.rawValue) }
    }
    public var theme: AppTheme {
        didSet { persist(.theme, theme.rawValue) }
    }

    private let store: PreferenceStore
    private var isReloading = false

    public init(store: PreferenceStore) {
        self.store = store
        self.markAsRead = Self.readEnum(
            .markAsRead, store: store, default: .manual
        )
        self.loadRemoteContent = Self.readEnum(
            .loadRemoteContent, store: store, default: .off
        )
        self.defaultFromAddress = store.stringValue(forKey: Key.defaultFromAddress.rawValue)
        self.signature = store.stringValue(forKey: Key.signature.rawValue) ?? ""
        self.disposeAction = Self.readEnum(
            .disposeAction, store: store, default: .archive
        )
        self.theme = Self.readEnum(.theme, store: store, default: .system)
        store.startObserving { [weak self] in
            self?.reload()
        }
    }

    /// Re-reads every preference from the store without firing persistence
    /// hooks. Called when the store signals an external change.
    public func reload() {
        isReloading = true
        defer { isReloading = false }
        markAsRead = Self.readEnum(.markAsRead, store: store, default: .manual)
        loadRemoteContent = Self.readEnum(
            .loadRemoteContent, store: store, default: .off
        )
        defaultFromAddress = store.stringValue(forKey: Key.defaultFromAddress.rawValue)
        signature = store.stringValue(forKey: Key.signature.rawValue) ?? ""
        disposeAction = Self.readEnum(.disposeAction, store: store, default: .archive)
        theme = Self.readEnum(.theme, store: store, default: .system)
    }

    private func persist(_ key: Key, _ value: String?) {
        guard !isReloading else { return }
        store.setString(value, forKey: key.rawValue)
    }

    private static func readEnum<Value: RawRepresentable>(
        _ key: Key, store: PreferenceStore, default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = store.stringValue(forKey: key.rawValue) else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }
}

// MARK: - In-memory store (tests + previews)

/// Storage adapter that keeps values in a dictionary. Useful for SwiftUI
/// previews and unit tests — `simulateExternalChange(_:)` mimics the iCloud
/// push notification path that real deployments exercise.
@MainActor
public final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: String] = [:]
    private var handler: (@MainActor () -> Void)?

    public init(initialValues: [String: String] = [:]) {
        self.values = initialValues
    }

    public func stringValue(forKey key: String) -> String? {
        values[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    public func startObserving(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public func stopObserving() {
        handler = nil
    }

    /// Applies a mutation to the backing dictionary and then fires the
    /// external-change handler, as if another device pushed the change
    /// through iCloud's key-value store.
    public func simulateExternalChange(_ mutation: (InMemoryPreferenceStore) -> Void) {
        mutation(self)
        handler?()
    }

    /// Mutates the dictionary without firing the observer, mirroring a
    /// `UbiquitousPreferenceStore` write that originated locally.
    public func setSilently(_ value: String?, forKey key: String) {
        setString(value, forKey: key)
    }
}

// MARK: - Ubiquitous (iCloud + UserDefaults) store

#if canImport(Foundation) && !os(Linux)
/// Production `PreferenceStore` — writes go to both `UserDefaults` (fast
/// local reads) and `NSUbiquitousKeyValueStore` (cross-device sync).
///
/// iCloud pushes arrive on the main queue via
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification`; the store
/// forwards them to the `startObserving` handler, which drives
/// `Preferences.reload()` above.
///
/// The store still functions without an iCloud account — `NSUbiquitousKey
/// ValueStore` simply becomes a no-op, and `UserDefaults` carries the
/// whole load. On-device-only installs (privacy-conscious users who have
/// disabled iCloud) therefore degrade gracefully.
@MainActor
public final class UbiquitousPreferenceStore: PreferenceStore {
    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?
    private var handler: (@MainActor () -> Void)?

    public init(
        defaults: UserDefaults = .standard,
        cloud: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloud = cloud
        // Trigger an initial pull from the cloud store so first-launch-on-
        // a-second-device doesn't show defaults until a change arrives.
        cloud.synchronize()
    }

    public func stringValue(forKey key: String) -> String? {
        // Prefer the local value — it's either the most recent write from
        // this device or a cloud value we already mirrored here. Fall back
        // to the cloud store when a device is brand new and iCloud hasn't
        // yet fired the external-change notification.
        if let local = defaults.string(forKey: key) { return local }
        return cloud.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
            cloud.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            cloud.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    public func startObserving(_ handler: @escaping @MainActor () -> Void) {
        stopObserving()
        self.handler = handler
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            // Extract the Sendable payload on whichever queue Foundation
            // chose (main, per the registration), then hop explicitly to
            // the main actor for the stored-property writes. The `@MainActor`
            // annotation on this class makes `self` Sendable, which is what
            // lets the weak capture survive the `@Sendable` closure
            // signature the strict-concurrency `addObserver` requires.
            let changedKeys = (notification.userInfo?[
                NSUbiquitousKeyValueStoreChangedKeysKey
            ] as? [String]) ?? []
            MainActor.assumeIsolated {
                self?.applyExternalChanges(keys: changedKeys)
            }
        }
    }

    private func applyExternalChanges(keys: [String]) {
        for key in keys {
            if let value = cloud.string(forKey: key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        handler?()
    }

    public func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif
