// See AppDelegate.swift for why these are explicit `os(...)` guards:
// push ships on iOS and macOS; the visionOS build of the shared
// Cabalmail target must not compile this.
#if os(iOS) || os(macOS)
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import UserNotifications
import CabalmailKit
import CabalmailShared

/// Message coordinates from the APNs payload's `msgRef` dictionary, parsed
/// by CabalmailShared's `PushMessageCoordinates`, the same parse the NSE
/// uses: a uid of 0 and an empty `msg_id` read as nil. `uid` is a
/// best-effort hint stamped by the dispatch path; `msg_id` is the durable
/// identity (see `docs/0.11.x/push-notifications.md`). For notification
/// *actions* we use the uid as given rather than re-resolving through
/// `/push_envelope` — the backend sends the resolved uid when it can, and a
/// stale hint only costs a no-op flag/move on a message that already left
/// the folder. The NSE patches the server-resolved uid into msgRef when
/// enrichment succeeds, so a nil uid here means it genuinely never resolved.
struct PushMessageRef: Sendable {
    let folder: String
    let uid: UInt32?
    let messageID: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard let coordinates = PushMessageCoordinates(userInfo: userInfo) else { return nil }
        self.folder = coordinates.folder
        self.uid = coordinates.uid
        self.messageID = coordinates.messageID
    }

    /// The same coordinates in their wire form, for writing a msgRef.
    var coordinates: PushMessageCoordinates {
        PushMessageCoordinates(folder: folder, uid: uid, messageID: messageID)
    }

    /// The pushed message, when the payload named it by UID. A payload whose
    /// UID never resolved names it by Message-ID alone, which only the open
    /// route can follow. The payload carries no UIDVALIDITY.
    var messageRef: MessageRef? {
        uid.map { MessageRef(folder: folder, uid: $0, messageId: messageID) }
    }
}

/// The user's folder-scope choice for new-mail pushes (Notifications
/// settings, phase 5). Raw values are the UserDefaults wire format — don't
/// rename cases without migrating `PushSettings.folderScopeKey`.
enum PushFolderScope: String, CaseIterable {
    case inboxOnly
    case all
    case custom
}

/// Per-device push preferences, persisted in UserDefaults. Deliberately a
/// nonisolated enum (not state on `PushRegistrar`, which is @MainActor) so
/// SwiftUI property initializers can read the stored values synchronously.
///
/// This state is per *device* by design: the server keeps the resolved
/// folder list on this device's token row (`cabal-push-tokens`), so there is
/// no cross-device mirror in get/set_preferences — that would add a second
/// source of truth for something inherently device-scoped.
enum PushSettings {
    /// True once the user flips the master toggle off. Launches must then
    /// neither re-prompt for permission nor re-register the token until the
    /// user turns the toggle back on (`PushRegistrar.enablePush`).
    static let disabledKey = "cabalmail.push.userDisabled"
    /// Raw `PushFolderScope` value; absent means `.inboxOnly`.
    static let folderScopeKey = "cabalmail.push.folderScope"
    /// `/`-delimited folder paths for the `.custom` scope.
    static let chosenFoldersKey = "cabalmail.push.chosenFolders"

    // The `defaults` parameters are `PushRegistrar`'s, which is
    // `.standard` everywhere but the tests.

    static var isUserDisabled: Bool { isUserDisabled(in: .standard) }

    static func isUserDisabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: disabledKey)
    }

    static func setUserDisabled(_ disabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: disabledKey)
    }

    static var folderScope: PushFolderScope { folderScope(in: .standard) }

    static func folderScope(in defaults: UserDefaults) -> PushFolderScope {
        defaults.string(forKey: folderScopeKey)
            .flatMap(PushFolderScope.init(rawValue:)) ?? .inboxOnly
    }

    /// Defaults to INBOX so the "Choose folders" list opens with the one
    /// folder everyone expects preselected.
    static var chosenFolders: [String] { chosenFolders(in: .standard) }

    static func chosenFolders(in defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: chosenFoldersKey) ?? ["INBOX"]
    }

    static func setScope(
        _ scope: PushFolderScope, chosenFolders: [String], in defaults: UserDefaults = .standard
    ) {
        defaults.set(scope.rawValue, forKey: folderScopeKey)
        defaults.set(chosenFolders, forKey: chosenFoldersKey)
    }

    /// The explicit `enabled_folders` value every `/push_register` call
    /// sends. Always explicit — never nil/omitted — so the server row is
    /// deterministic after each registration rather than relying on the
    /// Lambda's preserve-stored-value behavior. `[]` is the server's
    /// "inbox only" reset; `["*"]` is all folders.
    static func enabledFolders(in defaults: UserDefaults) -> [String] {
        switch folderScope(in: defaults) {
        case .inboxOnly: return []
        case .all: return ["*"]
        case .custom: return chosenFolders(in: defaults)
        }
    }
}

/// The calls `PushRegistrar` makes on `UNUserNotificationCenter`. A seam so
/// the app-layer tests never prompt for permission, post a notification or
/// remove the delivered ones: their host is the real app, whose notification
/// center is the one these calls would reach.
@MainActor
struct PushNotificationCenter {
    var requestAuthorization: @MainActor (UNAuthorizationOptions) async -> Bool
    var add: @MainActor (sending UNNotificationRequest) async throws -> Void
    var removeAllDeliveredNotifications: @MainActor () -> Void

    static var live: PushNotificationCenter {
        PushNotificationCenter(
            requestAuthorization: { options in
                (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
            },
            add: { request in try await UNUserNotificationCenter.current().add(request) },
            removeAllDeliveredNotifications: {
                UNUserNotificationCenter.current().removeAllDeliveredNotifications()
            }
        )
    }
}

/// Owns the APNs registration lifecycle and the notification-action
/// handlers for the iOS and macOS apps (docs/0.11.x/push-notifications.md,
/// phases 1/3/4; macOS parity is phase 6). `SessionManager` drives the
/// session edges (`sessionDidStart` / `sessionWillEnd`), `AppDelegate` feeds
/// it token and action callbacks. One implementation for both platforms —
/// the UIKit/AppKit divergences live in small shims (`Platform` below and
/// `BackgroundTaskToken` at the bottom of the file).
///
/// A singleton (rather than something hung off `AppState`) because the
/// application-delegate callbacks it services — token registration,
/// background notification actions — can fire before SwiftUI has built any
/// state, e.g. on a cold background launch from a lock-screen action. The
/// app entry hands it the session manager before any of that can happen,
/// and the actions borrow that manager's client.
@MainActor
public final class PushRegistrar {
    public static let shared = PushRegistrar()

    /// The two values `/push_register` derives the APNs topic from. The
    /// Lambda validates the pair (`com.cabalmail.Cabalmail` -> `ios`,
    /// `com.cabalmail.CabalmailMac` -> `macos`); `platform` itself is
    /// informational — `bundle_id` is authoritative server-side.
    private enum Platform {
        #if os(iOS)
        static let name = "ios"
        static let fallbackBundleId = "com.cabalmail.Cabalmail"
        #else
        static let name = "macos"
        static let fallbackBundleId = "com.cabalmail.CabalmailMac"
        #endif

        /// One seam over UIKit/AppKit's identically-named registration
        /// call. Both must run on the main thread; the explicit @MainActor
        /// is required because nested types don't inherit the enclosing
        /// class's isolation.
        @MainActor
        static func registerForRemoteNotifications() {
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #else
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    /// Set by `sessionDidStart`; navigation targets (`navCoordinator`)
    /// hang off it. Weak — the registrar outlives any session.
    private(set) weak var appState: AppState?

    /// The process's session manager, handed in by the app entry
    /// (`attach(_:)`); the actions and the enrichment borrow its client.
    private var sessions: SessionManager?

    /// The wired session's client, from `sessionDidStart` until
    /// `sessionWillEnd` has deregistered: what token registration and
    /// deregistration use. A token that arrives outside that window parks
    /// for the next session rather than register with one that is ending.
    private var sessionClient: CabalmailClient?

    /// APNs token that arrived before a session was wired (the system
    /// re-delivers the token on every `registerForRemoteNotifications`,
    /// which can beat the launch restore). Registered as soon as the
    /// session starts.
    private var pendingToken: String?

    /// A tapped notification that arrived before sign-in / restore
    /// completed; routed once the session is wired, unless the session is
    /// another account's (`forgetOtherAccount`) or ends first.
    private var pendingOpen: PushMessageRef?

    /// The notification center, the defaults the registrar's keys and
    /// `PushSettings` live in, and the NSE's shared containers: the real ones
    /// everywhere but the app-layer tests.
    private let notificationCenter: PushNotificationCenter
    private let defaults: UserDefaults
    private let enrichmentStore: PushEnrichmentStore

    /// UserDefaults key for the token most recently accepted by
    /// `/push_register` — i.e. what sign-out must deregister.
    static let lastTokenKey = "cabalmail.push.lastRegisteredToken"
    /// UserDefaults key for the account (`username@controlDomain`) of the
    /// last session that started, kept across sign-outs and launches: the
    /// account whose notifications may still be delivered (#1872).
    static let lastAccountKey = "cabalmail.push.lastSessionAccount"

    init(
        notificationCenter: PushNotificationCenter = .live,
        defaults: UserDefaults = .standard,
        enrichmentStore: PushEnrichmentStore = PushEnrichmentStore()
    ) {
        self.notificationCenter = notificationCenter
        self.defaults = defaults
        self.enrichmentStore = enrichmentStore
    }

    /// Called once from the app entry's init, before any scene exists and so
    /// before a delegate callback can need a client.
    public func attach(_ sessions: SessionManager) {
        self.sessions = sessions
    }

    /// Registers the `MAIL_MESSAGE` category the dispatch Lambda stamps on
    /// every payload. Called once at launch from `AppDelegate`.
    static func registerNotificationCategories() {
        let category = UNNotificationCategory(
            identifier: "MAIL_MESSAGE",
            actions: [
                UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground]),
                UNNotificationAction(identifier: "MARK_READ", title: "Mark as Read", options: []),
                UNNotificationAction(identifier: "ARCHIVE", title: "Archive", options: []),
            ],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Wires a signed-in session: mirrors the API URL for the NSE, asks for
    /// notification permission, and (re-)registers for remote notifications.
    /// The system re-delivers the device token on every registration, so
    /// each launch refreshes the server row — a cheap upsert by design.
    func sessionDidStart(appState: AppState, client: CabalmailClient) {
        self.appState = appState
        self.sessionClient = client
        forgetOtherAccount("\(appState.lastUsername)@\(appState.controlDomain)")
        enrichmentStore.updateAPIURL(client.configuration.invokeUrl)
        // Honor the user's master toggle: once notifications are off, a
        // launch neither re-prompts nor re-registers — only `enablePush`
        // (the Settings toggle) restarts the pipeline.
        if !PushSettings.isUserDisabled(in: defaults) {
            Task {
                guard await notificationCenter.requestAuthorization([.alert, .badge, .sound]) else { return }
                Platform.registerForRemoteNotifications()
            }
        }
        if let token = pendingToken {
            pendingToken = nil
            deviceTokenDidChange(token)
        }
        if let open = pendingOpen {
            pendingOpen = nil
            route(open)
        }
    }

    /// A notification names its message only by folder and UID, which mean
    /// something only in the account it was delivered for (#1872). When a
    /// session starts for another account than the last one, what the last
    /// one left goes before anything is replayed: a tap parked while no
    /// session was wired, and the notifications still delivered, whose
    /// actions would otherwise run against this account. The same account
    /// keeps both. With no account remembered (the first session since this
    /// was added), nothing is dropped. A control domain holds no `@`, so
    /// `account` names one pair.
    private func forgetOtherAccount(_ account: String) {
        defer { defaults.set(account, forKey: Self.lastAccountKey) }
        guard let last = defaults.string(forKey: Self.lastAccountKey), last != account else { return }
        pendingOpen = nil
        notificationCenter.removeAllDeliveredNotifications()
    }

    /// Called with the hex-encoded APNs token — on every launch (the
    /// system re-delivers it) and whenever APNs rotates it. Every
    /// registration carries the explicit current folder scope
    /// (`PushSettings.enabledFolders`), so the server row always reflects
    /// this device's latest choice.
    func deviceTokenDidChange(_ tokenHex: String) {
        // The system can re-deliver a token after the user flipped the
        // master toggle off (e.g. a rotation callback racing the toggle);
        // registering it would silently re-enable pushes.
        guard !PushSettings.isUserDisabled(in: defaults) else { return }
        guard let client = sessionClient else {
            pendingToken = tokenHex
            return
        }
        let registration = PushDeviceRegistration(
            deviceToken: tokenHex,
            bundleId: Bundle.main.bundleIdentifier ?? Platform.fallbackBundleId,
            platform: Platform.name,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0",
            locale: Locale.current.identifier,
            enabledFolders: PushSettings.enabledFolders(in: defaults)
        )
        Task {
            do {
                try await client.apiClient.registerPushDevice(registration)
                // The user can flip the master toggle off while this
                // round trip is in flight; its upsert would then resurrect
                // the row disablePush just deleted — and with the disabled
                // flag set, no later launch would ever clean it up. This
                // Task is main-actor (class isolation), so the flag read is
                // ordered after any toggle that landed during the await.
                if PushSettings.isUserDisabled(in: defaults) {
                    try? await client.apiClient.deregisterPushDevice(token: tokenHex)
                    return
                }
                defaults.set(tokenHex, forKey: Self.lastTokenKey)
            } catch {
                // Best-effort: a failed registration means no pushes until
                // the next launch retries, never a broken sign-in.
                CabalmailLog.warn("Push", "push_register failed: \(error)")
            }
        }
    }

    /// Deregisters this device's token. Called from the session's sign-out
    /// *before* the Cognito tokens are wiped — `/push_deregister` needs an
    /// authenticated call like every other endpoint.
    func sessionWillEnd() async {
        // The session's notifications, and a tap parked for it, name messages
        // only by folder and UID: whoever signs in next must not act on them
        // (#1872).
        pendingOpen = nil
        notificationCenter.removeAllDeliveredNotifications()
        defer {
            sessionClient = nil
            appState = nil
            // Drop the NSE's mirrored credentials alongside the session
            // (also cleared by the mirroring store when the tokens are
            // removed; doing it here too keeps the edge explicit).
            enrichmentStore.clear()
        }
        guard
            let client = sessionClient,
            let token = defaults.string(forKey: Self.lastTokenKey)
        else { return }
        do {
            try await client.apiClient.deregisterPushDevice(token: token)
            defaults.removeObject(forKey: Self.lastTokenKey)
        } catch {
            // Best-effort: a row we fail to remove here is pruned by
            // push_dispatch the next time APNs rejects its token, and a
            // reinstall / re-sign-in upserts over it.
            CabalmailLog.warn("Push", "push_deregister failed: \(error)")
        }
    }
}

// MARK: - Notifications settings (phase 5)

extension PushRegistrar {
    /// Master toggle ON. Requests notification permission (a no-op prompt
    /// if already determined) and, when granted, clears the user-disabled
    /// flag and re-registers for remote notifications — the token callback
    /// then upserts the server row with the current folder scope. Returns
    /// false when the OS permission is (or just was) denied, so the toggle
    /// can reflect the real system state instead of lying.
    func enablePush() async -> Bool {
        guard await notificationCenter.requestAuthorization([.alert, .badge, .sound]) else { return false }
        PushSettings.setUserDisabled(false, in: defaults)
        Platform.registerForRemoteNotifications()
        return true
    }

    /// Master toggle OFF. Sets the user-disabled flag first — that alone
    /// stops `sessionDidStart` / `deviceTokenDidChange` from re-registering
    /// on future launches — then best-effort deregisters the stored token so
    /// the server stops dispatching immediately rather than at next APNs
    /// rejection.
    func disablePush() async {
        PushSettings.setUserDisabled(true, in: defaults)
        pendingToken = nil
        guard
            let client = await activeClient(),
            let token = defaults.string(forKey: Self.lastTokenKey)
        else { return }
        do {
            try await client.apiClient.deregisterPushDevice(token: token)
            defaults.removeObject(forKey: Self.lastTokenKey)
        } catch {
            // Best-effort, same posture as sessionWillEnd: a row we fail to
            // remove is pruned by push_dispatch on the next APNs rejection.
            CabalmailLog.warn("Push", "push_deregister failed: \(error)")
        }
    }

    /// Persists a folder-scope change and, while registered, immediately
    /// re-registers the stored token so the server row picks it up without
    /// waiting for the next launch (the `/push_register` upsert is cheap).
    func updateFolderScope(_ scope: PushFolderScope, chosenFolders: [String]) {
        PushSettings.setScope(scope, chosenFolders: chosenFolders, in: defaults)
        guard
            !PushSettings.isUserDisabled(in: defaults),
            let token = defaults.string(forKey: Self.lastTokenKey)
        else { return }
        deviceTokenDidChange(token)
    }
}

// MARK: - Notification actions

extension PushRegistrar {
    /// Dispatches a notification response. Runs the IMAP work inside a
    /// background task (a real UIKit one on iOS, a no-op shim on macOS)
    /// and returns only once the operation resolves, so `AppDelegate` can
    /// end the system's action budget truthfully.
    func handleNotificationAction(identifier: String, ref: PushMessageRef?) async {
        switch identifier {
        case "MARK_READ":
            guard let message = ref?.messageRef else { return }
            await withBackgroundTask(named: "cabal.push.markRead") { client in
                try await client.imapClient.setFlags(
                    folder: message.folder,
                    uids: [message.uid],
                    flags: [.seen],
                    operation: .add
                )
            }
        case "ARCHIVE":
            guard let message = ref?.messageRef else { return }
            await withBackgroundTask(named: "cabal.push.archive") { client in
                // Archive == read, in one round trip (server marks `\Seen`
                // before moving) — this runs on the notification action's
                // brief background budget, so the fewer calls the better.
                // The destination is the in-app archive's: Dovecot creates
                // `Archive` for every mailbox, so it needs no lookup, and no
                // remembered path can outlive the account it came from
                // (#1882).
                try await client.imapClient.move(
                    folder: message.folder,
                    uids: [message.uid],
                    destination: DisposeAction.archive.destinationFolder,
                    markSeen: true
                )
            }
        case "OPEN", UNNotificationDefaultActionIdentifier:
            guard let ref else { return }
            route(ref)
        default:
            break
        }
    }

    /// Routes the app to the pushed message. While signed in this drives
    /// the same `navigateRequest` machinery as the cross-device resume
    /// toast; before the session is wired (cold launch from a tap) the ref
    /// parks here and `sessionDidStart` re-routes it — a window's first
    /// landing drains a request parked before it (`SceneNavigator`).
    private func route(_ ref: PushMessageRef) {
        guard let coordinator = appState?.navCoordinator else {
            pendingOpen = ref
            return
        }
        coordinator.navigateRequest = NavState(
            folder: ref.folder,
            messageID: ref.messageID,
            uid: ref.uid,
            clientID: coordinator.clientID
        )
    }
}

// MARK: - Silent-push enrichment (macOS)

#if os(macOS)
extension PushRegistrar {
    /// Enriches a silent push while the app is running. macOS's
    /// notification daemon kills our Notification Service Extension before
    /// `didReceive` ever runs (the long-standing "sluggish startup" platform
    /// defect — Apple forums threads 693011 / 806789), so the server sends
    /// Macs a background push instead of an alert and the running app does
    /// the NSE's job itself: fetch the envelope through the session client
    /// and post an enriched *local* notification, whose presentation then
    /// follows the app's `willPresent` policy (sound only while active, full
    /// banner otherwise). Called from `AppDelegate`'s
    /// `didReceiveRemoteNotification`, which fires for a running app
    /// regardless of focus. Returns false on any failure so the caller can
    /// post the generic fallback (`presentGenericNotification`) — a generic
    /// banner beats a silent drop. The NSE stays shipped as-is; if Apple
    /// fixes the platform it takes over the app-not-running case.
    func presentEnrichedNotification(for ref: PushMessageRef) async -> Bool {
        guard let client = await activeClient() else {
            CabalmailLog.warn("Push", "silent-push enrichment skipped: no signed-in session")
            return false
        }
        do {
            let envelope = try await client.apiClient.fetchPushEnvelope(
                folder: ref.folder,
                uid: ref.uid,
                messageID: ref.messageID
            )
            let content = UNMutableNotificationContent()
            content.title = envelope.from
            content.body = envelope.subject + "\n" + envelope.snippet
            content.sound = .default
            content.categoryIdentifier = "MAIL_MESSAGE"
            // Same msgRef contract as the dispatch payload, carrying the
            // server-resolved uid (the push's was a pre-delivery hint; 0
            // is the "unresolved" sentinel, and a missing resolution keeps
            // the original hint) so Mark as Read / Archive / Open act on
            // the message this notification shows.
            content.userInfo = ref.coordinates.resolving(envelope.uid).userInfo
            try await notificationCenter.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
            return true
        } catch {
            CabalmailLog.warn("Push", "silent-push enrichment failed: \(error)")
            return false
        }
    }

    /// Fallback for a failed enrichment: posts the same generic "New mail"
    /// notification an alert push used to show, carrying the silent push's
    /// msgRef so the notification actions still work. Without this a fetch
    /// failure would turn the silent push into no notification at all.
    func presentGenericNotification(for ref: PushMessageRef) async {
        let content = UNMutableNotificationContent()
        content.title = "New mail"
        content.sound = .default
        content.categoryIdentifier = "MAIL_MESSAGE"
        content.userInfo = ref.coordinates.userInfo
        do {
            try await notificationCenter.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
        } catch {
            CabalmailLog.warn("Push", "generic fallback notification failed: \(error)")
        }
    }
}
#endif

// MARK: - Background execution plumbing

extension PushRegistrar {
    /// Runs `work` with an active session client inside a background task
    /// (see `BackgroundTaskToken`), so an iOS lock-screen action started
    /// with the app suspended isn't killed mid-flight. Errors are logged,
    /// not surfaced — there is no UI to surface them to.
    private func withBackgroundTask(
        named name: String,
        _ work: (CabalmailClient) async throws -> Void
    ) async {
        let token = BackgroundTaskToken()
        token.begin(named: name)
        defer { token.end() }
        guard let client = await activeClient() else {
            CabalmailLog.warn("Push", "\(name) skipped: no signed-in session")
            return
        }
        do {
            try await work(client)
            // The action just mutated a folder server-side; if the app is
            // running, its open views only learn of external changes on the
            // next poll — nudge the shared refresh tick so Mark as Read /
            // Archive appear immediately instead of at the poll boundary.
            appState?.requestRefresh()
        } catch {
            CabalmailLog.warn("Push", "\(name) failed: \(error)")
        }
    }

    /// The session's client, borrowed from the session manager: the wired
    /// session's, or on a cold background launch (no scene, so no restore)
    /// the stored account's, which the manager builds once and the next
    /// restore adopts. Nil when signed out, or when building it failed.
    private func activeClient() async -> CabalmailClient? {
        do {
            return try await sessions?.borrowClient()
        } catch {
            CabalmailLog.warn("Push", "no client to borrow: \(error)")
            return nil
        }
    }
}

#if os(iOS)
/// Minimal RAII-ish wrapper around `beginBackgroundTask` /
/// `endBackgroundTask`. Class (not struct) so the expiration handler can
/// reach back and end the task if the system calls time first.
@MainActor
private final class BackgroundTaskToken {
    private var id: UIBackgroundTaskIdentifier = .invalid

    func begin(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#else
/// macOS has no `beginBackgroundTask` equivalent and doesn't need one:
/// mac apps aren't suspended mid-notification-action, so the work in
/// `withBackgroundTask` runs to completion on its own. A no-op shim (same
/// shape as the iOS class) keeps the call site platform-neutral.
@MainActor
private final class BackgroundTaskToken {
    func begin(named name: String) {}
    func end() {}
}
#endif
#endif
