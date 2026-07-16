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

/// Default rendering mode when a message's HTML body first appears.
///
/// `.original` hands the author's HTML to `WKWebView` untouched (minus the
/// tracker-pixel blocker). `.reader` prepends a stylesheet that overrides
/// author CSS — system font, capped line length, dark-mode aware — for a
/// Safari Reader-style presentation. The user can still flip modes per-
/// message from the detail toolbar; this preference only chooses which side
/// of the toggle the detail view lands on when it opens.
public enum BodyRenderMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case original
    case reader

    public var id: String { rawValue }
}

/// Which number(s) to show next to each folder in the sidebar.
///
/// `.unread` is the historical behavior — a single count of UNSEEN messages.
/// `.total` matches mailbox managers (and what an IMAP `STATUS (MESSAGES)`
/// returns) for users who care about volume rather than attention. `.both`
/// renders as `unread/total` so both numbers are visible at a glance.
public enum FolderCountDisplay: String, Codable, Sendable, CaseIterable, Identifiable {
    case unread
    case total
    case both

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
        case crashReportingEnabled = "cabalmail.prefs.crash_reporting_enabled"
        case defaultBodyRenderMode = "cabalmail.prefs.default_body_render_mode"
        case folderCountDisplay = "cabalmail.prefs.folder_count_display"
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
    /// Opt-in MetricKit-backed crash / hang reporting. Disabled by default
    /// per the Phase 7 plan — when the user flips this, `CabalmailClient`
    /// starts (or stops) its `MetricKitCollector`, which funnels diagnostic
    /// payloads into `DebugLogStore` so they surface in the Debug Log view.
    public var crashReportingEnabled: Bool {
        didSet { persist(.crashReportingEnabled, crashReportingEnabled ? "1" : "0") }
    }
    public var defaultBodyRenderMode: BodyRenderMode {
        didSet { persist(.defaultBodyRenderMode, defaultBodyRenderMode.rawValue) }
    }
    /// Sidebar folder-count rendering. Defaults to `.unread` to match the
    /// pre-existing behavior so users who never visit Settings see no change.
    public var folderCountDisplay: FolderCountDisplay {
        didSet { persist(.folderCountDisplay, folderCountDisplay.rawValue) }
    }

    private let store: PreferenceStore
    private var isReloading = false
    private var isApplyingRemote = false

    /// Fired after a user-driven preference write, once the new value has been
    /// persisted locally. The session's `PreferencesSyncCoordinator` sets this
    /// to debounce a push of the full `app` map to the server so settings
    /// follow the Cabalmail account across devices. Deliberately *not* fired
    /// for the `reload()` (inbound iCloud) or `applyRemote(_:)` (inbound
    /// server) paths — echoing an inbound update back out would loop.
    public var onLocalChange: (() -> Void)?

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
        self.crashReportingEnabled = store.stringValue(
            forKey: Key.crashReportingEnabled.rawValue
        ) == "1"
        self.defaultBodyRenderMode = Self.readEnum(
            .defaultBodyRenderMode, store: store, default: .original
        )
        self.folderCountDisplay = Self.readEnum(
            .folderCountDisplay, store: store, default: .unread
        )
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
        crashReportingEnabled = store.stringValue(
            forKey: Key.crashReportingEnabled.rawValue
        ) == "1"
        defaultBodyRenderMode = Self.readEnum(
            .defaultBodyRenderMode, store: store, default: .original
        )
        folderCountDisplay = Self.readEnum(
            .folderCountDisplay, store: store, default: .unread
        )
    }

    private func persist(_ key: Key, _ value: String?) {
        guard !isReloading else { return }
        store.setString(value, forKey: key.rawValue)
        // A server-applied value is already persisted locally by the write
        // above; it must not be pushed straight back to the server, or a
        // fetched change would echo out as a fresh save. Only genuine user
        // edits fall through to notify the sync coordinator.
        guard !isApplyingRemote else { return }
        onLocalChange?()
    }

    private static func readEnum<Value: RawRepresentable>(
        _ key: Key, store: PreferenceStore, default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = store.stringValue(forKey: key.rawValue) else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }

    // MARK: - Server sync marshalling

    /// Wire keys for the server-synced `app` map (the `set_preferences` Lambda
    /// validates against these exact names). Distinct from `Key`, whose dotted
    /// raw values are the local UserDefaults/iCloud keys; these short
    /// snake_case names are the cross-client JSON contract.
    private enum AppWireKey {
        static let markAsRead = "mark_as_read"
        static let loadRemoteContent = "load_remote_content"
        static let defaultFromAddress = "default_from_address"
        static let signature = "signature"
        static let disposeAction = "dispose_action"
        static let theme = "theme"
        static let crashReportingEnabled = "crash_reporting_enabled"
        static let defaultBodyRenderMode = "default_body_render_mode"
        static let folderCountDisplay = "folder_count_display"
    }

    /// The complete set of synced preferences as the `app` map the server
    /// stores. Always sends every key (the server replaces the whole map), with
    /// `defaultFromAddress`'s "no default" (`nil`) encoded as an empty string.
    public func appPreferencesPayload() -> [String: String] {
        [
            AppWireKey.markAsRead: markAsRead.rawValue,
            AppWireKey.loadRemoteContent: loadRemoteContent.rawValue,
            AppWireKey.defaultFromAddress: defaultFromAddress ?? "",
            AppWireKey.signature: signature,
            AppWireKey.disposeAction: disposeAction.rawValue,
            AppWireKey.theme: theme.rawValue,
            AppWireKey.crashReportingEnabled: crashReportingEnabled ? "1" : "0",
            AppWireKey.defaultBodyRenderMode: defaultBodyRenderMode.rawValue,
            AppWireKey.folderCountDisplay: folderCountDisplay.rawValue,
        ]
    }

    /// Applies a server-fetched `app` map (server wins on login). Each value is
    /// written through to the local store as a cache, but `isApplyingRemote`
    /// suppresses the `onLocalChange` push so the fetch doesn't bounce back out.
    /// Missing or unrecognized values leave the current value untouched.
    public func applyRemote(_ remote: [String: String]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if let raw = remote[AppWireKey.markAsRead], let value = MarkAsReadBehavior(rawValue: raw) {
            markAsRead = value
        }
        if let raw = remote[AppWireKey.loadRemoteContent], let value = LoadRemoteContentPolicy(rawValue: raw) {
            loadRemoteContent = value
        }
        if let raw = remote[AppWireKey.defaultFromAddress] {
            // Empty string is the wire encoding for "no default".
            defaultFromAddress = raw.isEmpty ? nil : raw
        }
        if let raw = remote[AppWireKey.signature] {
            signature = raw
        }
        if let raw = remote[AppWireKey.disposeAction], let value = DisposeAction(rawValue: raw) {
            disposeAction = value
        }
        if let raw = remote[AppWireKey.theme], let value = AppTheme(rawValue: raw) {
            theme = value
        }
        if let raw = remote[AppWireKey.crashReportingEnabled] {
            crashReportingEnabled = raw == "1"
        }
        if let raw = remote[AppWireKey.defaultBodyRenderMode], let value = BodyRenderMode(rawValue: raw) {
            defaultBodyRenderMode = value
        }
        if let raw = remote[AppWireKey.folderCountDisplay], let value = FolderCountDisplay(rawValue: raw) {
            folderCountDisplay = value
        }
    }
}

// Concrete `PreferenceStore` implementations live in sibling files:
// `InMemoryPreferenceStore.swift` (tests + previews) and
// `UbiquitousPreferenceStore.swift` (production, UserDefaults + iCloud).
