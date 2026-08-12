import Foundation
import Observation

// User-facing behavior toggles persisted across launches (per Cabalmail
// account, in local `UserDefaults`) and synced between the user's devices
// through the server's per-user preferences row — never through iCloud.
//
// Phase 6 scope (`docs/0.6.x/ios-client-plan.md`) covers four surfaces:
// Reading (mark-as-read + remote-content gating), Composing (default From
// + signature), Actions (dispose swipe target), Appearance (theme).
//
// The `Preferences` class below is intentionally `@MainActor` +
// `@Observable` — SwiftUI views bind directly to its mutable properties,
// and read access happens synchronously on the main queue where every
// SwiftUI body already runs. A paired `PreferenceStore` abstraction keeps
// the storage side pluggable so tests can exercise external-change handling
// without reaching for the real `UserDefaults`.

// MARK: - Enums

/// How the reader marks a message read when the detail view opens.
///
/// Defaults to `.manual` per the plan — a behavior that matches the React
/// app, where the user always explicitly marks messages read via the swipe
/// action, toolbar button, or context menu.
public enum MarkAsReadBehavior: String, Codable, Sendable, CaseIterable, Identifiable {
    case manual
    case onOpen = "on_open"

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

/// Which message the reading pane advances to after the open message is
/// disposed (archived, deleted, or purged) from the reader.
///
/// `.nextUnread` is the historical behavior — triage skips straight to the
/// next message needing attention. `.next` walks the list in its current
/// ordering regardless of read state; `.previousUnread` walks the other
/// direction; `.firstUnread` jumps back to the topmost unread.
public enum DisposeAdvance: String, Codable, Sendable, CaseIterable, Identifiable {
    case next
    case nextUnread = "next_unread"
    case previousUnread = "previous_unread"
    case firstUnread = "first_unread"

    public var id: String { rawValue }
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
/// Production wires a `UserDefaultsPreferenceStore` — local-only on
/// purpose; cross-device sync goes through the server's per-user
/// preferences row, never iCloud. Tests inject `InMemoryPreferenceStore`
/// and drive external-change semantics via `simulateExternalChange(_:)`.
///
/// The protocol is `@MainActor`-bound so `Preferences` — also `@MainActor`
/// — can call into the store without actor hops. Strict concurrency on this
/// project is `complete`, so that isolation has to be explicit.
@MainActor
public protocol PreferenceStore: AnyObject {
    func stringValue(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)

    /// Registers the single external-change handler the store invokes when
    /// a value changes underneath `Preferences` (a no-op for the production
    /// `UserDefaults` store; `InMemoryPreferenceStore` fires it from
    /// `simulateExternalChange`). The store retains the handler until
    /// `stopObserving()` or store deinit. Calling twice replaces the
    /// previous handler.
    func startObserving(_ handler: @escaping @MainActor () -> Void)
    func stopObserving()
}

// MARK: - Preferences

/// Observable preferences surface consumed by views and view models.
///
/// Persists to its `PreferenceStore` synchronously in each property's
/// `didSet`. Store-driven updates land through `reload()`, which sets
/// `isReloading` to suppress the persistence hooks while it rewrites
/// stored state — preventing a reload from re-persisting (or echoing to
/// the server as an edit) the values it just read.
///
/// Storage is scoped **per Cabalmail account**: `activate(controlDomain:
/// username:)` switches every read and write to that account's own keys
/// and reloads. Until the first activation the properties carry their
/// defaults and writes stay in memory. This is what keeps one account's
/// settings — the default From address especially — from surviving a
/// sign-out and showing up for (or being overwritten by) the next account
/// on the same device; the server copy (`applyRemote(_:)`, per Cognito
/// user) is the cross-device authority layered on top. The local store is
/// this device's `UserDefaults` only — settings never touch iCloud.
@Observable
@MainActor
public final class Preferences {
    /// Canonical keys for every stored preference. Each account's value
    /// lives at `rawValue` + `"."` + the account's scope hash (see
    /// `storageKey(_:)`); the bare rawValue is the legacy device-wide key
    /// from before account scoping, which `activate` deletes so no account
    /// can inherit another's settings. These strings are load-bearing —
    /// don't rename without a migration.
    public enum Key: String, CaseIterable, Sendable {
        case markAsRead = "cabalmail.prefs.mark_as_read"
        case loadRemoteContent = "cabalmail.prefs.load_remote_content"
        case defaultFromAddress = "cabalmail.prefs.default_from_address"
        case signature = "cabalmail.prefs.signature"
        case disposeAction = "cabalmail.prefs.dispose_action"
        case disposeAdvance = "cabalmail.prefs.dispose_advance"
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
    /// Which message the reader advances to after a dispose. Defaults to
    /// `.nextUnread`, the behavior from before this was a preference.
    public var disposeAdvance: DisposeAdvance {
        didSet { persist(.disposeAdvance, disposeAdvance.rawValue) }
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

    /// Scope hash of the account whose settings are currently loaded, or
    /// `nil` before the first `activate` (fresh install, first launch
    /// signed out). While `nil`, reads fall back to defaults and writes
    /// are not persisted.
    public private(set) var accountScope: String?

    /// Fired after a user-driven preference write, once the new value has been
    /// persisted locally. The session's `PreferencesSyncCoordinator` sets this
    /// to debounce a push of the full `app` map to the server so settings
    /// follow the Cabalmail account across devices. Deliberately *not* fired
    /// for the `reload()` (store change / account switch) or `applyRemote(_:)`
    /// (inbound server) paths — echoing an inbound update back out would loop.
    public var onLocalChange: (() -> Void)?

    public init(store: PreferenceStore) {
        self.store = store
        // Pure defaults: which account's stored values apply isn't known
        // until `activate` names one. Assignments in an initializer don't
        // fire `didSet`, so nothing persists here.
        self.markAsRead = .manual
        self.loadRemoteContent = .off
        self.defaultFromAddress = nil
        self.signature = ""
        self.disposeAction = .archive
        self.disposeAdvance = .nextUnread
        self.theme = .system
        self.crashReportingEnabled = false
        self.defaultBodyRenderMode = .original
        self.folderCountDisplay = .unread
        store.startObserving { [weak self] in
            self?.reload()
        }
    }

    // MARK: - Account scoping

    /// Stable per-account scope hash (FNV-1a 64 of the normalized control
    /// domain + username). Hashing keeps usernames out of stored key names
    /// and the key length bounded regardless of username length. `nil`
    /// when either input is empty.
    static func scopeIdentifier(controlDomain: String, username: String) -> String? {
        let domain = controlDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !domain.isEmpty, !user.isEmpty else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(domain)|\(user)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Switches the loaded settings to `username`'s account and reloads
    /// every property from that account's stored values (defaults on its
    /// first sign-in). Called on sign-in / session restore; sign-out
    /// deliberately leaves the last scope active so the signed-out UI
    /// (theme, the macOS Settings scene) doesn't snap to defaults. No-op
    /// when the inputs are empty or the account is already active.
    ///
    /// Also deletes any values still stored under the legacy device-wide
    /// keys. Those keys were shared across accounts, which is exactly the
    /// leak this scoping closes; leaving them behind would hand one
    /// account's settings (default From address included) to the next
    /// account that signs in.
    public func activate(controlDomain: String, username: String) {
        guard let scope = Self.scopeIdentifier(
            controlDomain: controlDomain, username: username
        ) else { return }
        guard scope != accountScope else { return }
        accountScope = scope
        purgeLegacyUnscopedValues()
        reload()
    }

    /// The store key for `key` under the active account, or `nil` while no
    /// account is active. Suffixes (rather than replaces) the legacy key so
    /// every stored name keeps the greppable `cabalmail.prefs.` prefix.
    func storageKey(_ key: Key) -> String? {
        guard let accountScope else { return nil }
        return "\(key.rawValue).\(accountScope)"
    }

    private func purgeLegacyUnscopedValues() {
        for key in Key.allCases where store.stringValue(forKey: key.rawValue) != nil {
            store.setString(nil, forKey: key.rawValue)
        }
    }

    // MARK: - Store round-trips

    /// Re-reads every preference from the store without firing persistence
    /// hooks. Called when the store signals an external change and after
    /// `activate` swaps the account scope.
    public func reload() {
        isReloading = true
        defer { isReloading = false }
        markAsRead = readEnum(.markAsRead, default: .manual)
        loadRemoteContent = readEnum(.loadRemoteContent, default: .off)
        defaultFromAddress = readString(.defaultFromAddress)
        signature = readString(.signature) ?? ""
        disposeAction = readEnum(.disposeAction, default: .archive)
        disposeAdvance = readEnum(.disposeAdvance, default: .nextUnread)
        theme = readEnum(.theme, default: .system)
        crashReportingEnabled = readString(.crashReportingEnabled) == "1"
        defaultBodyRenderMode = readEnum(.defaultBodyRenderMode, default: .original)
        folderCountDisplay = readEnum(.folderCountDisplay, default: .unread)
    }

    private func persist(_ key: Key, _ value: String?) {
        guard !isReloading else { return }
        if let storageKey = storageKey(key) {
            store.setString(value, forKey: storageKey)
        }
        // A server-applied value is already persisted locally by the write
        // above; it must not be pushed straight back to the server, or a
        // fetched change would echo out as a fresh save. Only genuine user
        // edits fall through to notify the sync coordinator.
        guard !isApplyingRemote else { return }
        onLocalChange?()
    }

    private func readString(_ key: Key) -> String? {
        guard let storageKey = storageKey(key) else { return nil }
        return store.stringValue(forKey: storageKey)
    }

    private func readEnum<Value: RawRepresentable>(
        _ key: Key, default fallback: Value
    ) -> Value where Value.RawValue == String {
        guard let raw = readString(key) else { return fallback }
        return Value(rawValue: raw) ?? fallback
    }

    // MARK: - Reconciliation

    /// Clears the default From address when it isn't one of the account's
    /// own addresses. Callers pass the freshly fetched address list; an
    /// empty list is treated as inconclusive (a transient fetch hiccup must
    /// not wipe a valid default), so nothing is cleared.
    ///
    /// A dangling default reaches this state two ways: the address was
    /// revoked from another device, or the value predates per-account
    /// scoping and leaked in from a different account — possibly laundered
    /// through the server's per-user preferences row, which "server wins on
    /// login" then re-applies on every sign-in. Clearing here goes through
    /// the normal persistence hooks, so the sync coordinator pushes the
    /// cleared value back to the server and the bad row heals durably.
    public func reconcileDefaultFromAddress(available: [String]) {
        guard let current = defaultFromAddress, !available.isEmpty else { return }
        guard !available.contains(current) else { return }
        defaultFromAddress = nil
    }

    // MARK: - Server sync marshalling

    /// Wire keys for the server-synced `app` map (the `set_preferences` Lambda
    /// validates against these exact names). Distinct from `Key`, whose dotted
    /// raw values are the local UserDefaults keys; these short snake_case
    /// names are the cross-client JSON contract.
    private enum AppWireKey {
        static let markAsRead = "mark_as_read"
        static let loadRemoteContent = "load_remote_content"
        static let defaultFromAddress = "default_from_address"
        static let signature = "signature"
        static let disposeAction = "dispose_action"
        static let disposeAdvance = "dispose_advance"
        static let theme = "theme"
        static let crashReportingEnabled = "crash_reporting_enabled"
        static let defaultBodyRenderMode = "default_body_render_mode"
        static let folderCountDisplay = "folder_count_display"
    }

    /// The complete set of synced preferences as the `app` map the server
    /// stores. Always sends every key this build knows; the server merges
    /// per key, so keys a newer client added (and this build doesn't know)
    /// survive the push. `defaultFromAddress`'s "no default" (`nil`) is
    /// encoded as an empty string — key removal is never needed.
    public func appPreferencesPayload() -> [String: String] {
        [
            AppWireKey.markAsRead: markAsRead.rawValue,
            AppWireKey.loadRemoteContent: loadRemoteContent.rawValue,
            AppWireKey.defaultFromAddress: defaultFromAddress ?? "",
            AppWireKey.signature: signature,
            AppWireKey.disposeAction: disposeAction.rawValue,
            AppWireKey.disposeAdvance: disposeAdvance.rawValue,
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
        if let raw = remote[AppWireKey.disposeAdvance], let value = DisposeAdvance(rawValue: raw) {
            disposeAdvance = value
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
// `UserDefaultsPreferenceStore.swift` (production, local-only).
