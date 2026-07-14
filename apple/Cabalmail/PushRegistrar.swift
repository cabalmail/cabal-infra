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

/// Message coordinates from the APNs payload's `msgRef` dictionary:
/// `{"folder": "INBOX", "uid": 4271, "msg_id": "<...>"}`. `uid` is a
/// best-effort hint stamped by the dispatch path; `msg_id` is the durable
/// identity (see `docs/0.11.0/push-notifications.md`). For notification
/// *actions* we use the uid as given rather than re-resolving through
/// `/push_envelope` — the backend sends the resolved uid when it can, and a
/// stale hint only costs a no-op flag/move on a message that already left
/// the folder.
struct PushMessageRef: Sendable {
    let folder: String
    let uid: UInt32?
    let messageID: String?

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let ref = userInfo["msgRef"] as? [String: Any],
            let folder = ref["folder"] as? String, !folder.isEmpty
        else { return nil }
        self.folder = folder
        // 0 is the dispatch Lambda's "no hint" sentinel; mapping it to nil
        // makes the action handlers' `guard let uid` skip cleanly instead of
        // flag/move-ing UID 0 (which the API rejects as out of range). The
        // NSE rewrites msgRef with the server-resolved uid when enrichment
        // succeeds, so a nil here means the uid genuinely never resolved.
        let rawUid = (ref["uid"] as? NSNumber)?.uint32Value
        self.uid = rawUid == 0 ? nil : rawUid
        let rawMessageID = ref["msg_id"] as? String
        self.messageID = (rawMessageID?.isEmpty ?? true) ? nil : rawMessageID
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

    static var isUserDisabled: Bool {
        UserDefaults.standard.bool(forKey: disabledKey)
    }

    static func setUserDisabled(_ disabled: Bool) {
        UserDefaults.standard.set(disabled, forKey: disabledKey)
    }

    static var folderScope: PushFolderScope {
        UserDefaults.standard.string(forKey: folderScopeKey)
            .flatMap(PushFolderScope.init(rawValue:)) ?? .inboxOnly
    }

    /// Defaults to INBOX so the "Choose folders" list opens with the one
    /// folder everyone expects preselected.
    static var chosenFolders: [String] {
        UserDefaults.standard.stringArray(forKey: chosenFoldersKey) ?? ["INBOX"]
    }

    static func setScope(_ scope: PushFolderScope, chosenFolders: [String]) {
        UserDefaults.standard.set(scope.rawValue, forKey: folderScopeKey)
        UserDefaults.standard.set(chosenFolders, forKey: chosenFoldersKey)
    }

    /// The explicit `enabled_folders` value every `/push_register` call
    /// sends. Always explicit — never nil/omitted — so the server row is
    /// deterministic after each registration rather than relying on the
    /// Lambda's preserve-stored-value behavior. `[]` is the server's
    /// "inbox only" reset; `["*"]` is all folders.
    static var enabledFolders: [String] {
        switch folderScope {
        case .inboxOnly: return []
        case .all: return ["*"]
        case .custom: return chosenFolders
        }
    }
}

/// Owns the APNs registration lifecycle and the notification-action
/// handlers for the iOS and macOS apps (docs/0.11.0/push-notifications.md,
/// phases 1/3/4; macOS parity is phase 6). `AppState` drives the session
/// edges (`sessionDidStart` / `sessionWillEnd`), `AppDelegate` feeds it
/// token and action callbacks. One implementation for both platforms —
/// the UIKit/AppKit divergences live in small shims (`Platform` below and
/// `BackgroundTaskToken` at the bottom of the file).
///
/// A singleton (rather than something hung off `AppState`) because the
/// application-delegate callbacks it services — token registration,
/// background notification actions — can fire before SwiftUI has built any
/// state, e.g. on a cold background launch from a lock-screen action.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()

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

    /// The session client while signed in, or a throwaway bootstrap client
    /// built for a background action on a terminated app (`activeClient()`).
    private var client: CabalmailClient?

    /// APNs token that arrived before a session was wired (the system
    /// re-delivers the token on every `registerForRemoteNotifications`,
    /// which can beat the launch restore). Registered as soon as the
    /// session starts.
    private var pendingToken: String?

    /// A tapped notification that arrived before sign-in / restore
    /// completed; routed once the session is wired.
    private var pendingOpen: PushMessageRef?

    /// UserDefaults key for the token most recently accepted by
    /// `/push_register` — i.e. what sign-out must deregister.
    static let lastTokenKey = "cabalmail.push.lastRegisteredToken"
    /// Cached archive-folder path resolved by `archiveFolderPath(using:)`.
    /// A Settings-visible override is deferred to the preferences phase.
    static let archiveFolderKey = "cabalmail.push.archiveFolder"

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
        self.client = client
        PushEnrichmentStore().updateAPIURL(client.configuration.invokeUrl)
        // Honor the user's master toggle: once notifications are off, a
        // launch neither re-prompts nor re-registers — only `enablePush`
        // (the Settings toggle) restarts the pipeline.
        if !PushSettings.isUserDisabled {
            Task {
                let center = UNUserNotificationCenter.current()
                let granted = (try? await center.requestAuthorization(
                    options: [.alert, .badge, .sound]
                )) ?? false
                guard granted else { return }
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

    /// Called with the hex-encoded APNs token — on every launch (the
    /// system re-delivers it) and whenever APNs rotates it. Every
    /// registration carries the explicit current folder scope
    /// (`PushSettings.enabledFolders`), so the server row always reflects
    /// this device's latest choice.
    func deviceTokenDidChange(_ tokenHex: String) {
        // The system can re-deliver a token after the user flipped the
        // master toggle off (e.g. a rotation callback racing the toggle);
        // registering it would silently re-enable pushes.
        guard !PushSettings.isUserDisabled else { return }
        guard let client else {
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
            enabledFolders: PushSettings.enabledFolders
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
                if PushSettings.isUserDisabled {
                    try? await client.apiClient.deregisterPushDevice(token: tokenHex)
                    return
                }
                UserDefaults.standard.set(tokenHex, forKey: Self.lastTokenKey)
            } catch {
                // Best-effort: a failed registration means no pushes until
                // the next launch retries, never a broken sign-in.
                CabalmailLog.warn("Push", "push_register failed: \(error)")
            }
        }
    }

    /// Deregisters this device's token. Called from `AppState.signOut()`
    /// *before* the Cognito tokens are wiped — `/push_deregister` needs an
    /// authenticated call like every other endpoint.
    func sessionWillEnd() async {
        defer {
            client = nil
            appState = nil
            // Drop the NSE's mirrored credentials alongside the session
            // (also cleared by the mirroring store when the tokens are
            // removed; doing it here too keeps the edge explicit).
            PushEnrichmentStore().clear()
        }
        guard
            let client,
            let token = UserDefaults.standard.string(forKey: Self.lastTokenKey)
        else { return }
        do {
            try await client.apiClient.deregisterPushDevice(token: token)
            UserDefaults.standard.removeObject(forKey: Self.lastTokenKey)
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
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(
            options: [.alert, .badge, .sound]
        )) ?? false
        guard granted else { return false }
        PushSettings.setUserDisabled(false)
        Platform.registerForRemoteNotifications()
        return true
    }

    /// Master toggle OFF. Sets the user-disabled flag first — that alone
    /// stops `sessionDidStart` / `deviceTokenDidChange` from re-registering
    /// on future launches — then best-effort deregisters the stored token so
    /// the server stops dispatching immediately rather than at next APNs
    /// rejection.
    func disablePush() async {
        PushSettings.setUserDisabled(true)
        pendingToken = nil
        guard
            let client = await activeClient(),
            let token = UserDefaults.standard.string(forKey: Self.lastTokenKey)
        else { return }
        do {
            try await client.apiClient.deregisterPushDevice(token: token)
            UserDefaults.standard.removeObject(forKey: Self.lastTokenKey)
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
        PushSettings.setScope(scope, chosenFolders: chosenFolders)
        guard
            !PushSettings.isUserDisabled,
            let token = UserDefaults.standard.string(forKey: Self.lastTokenKey)
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
            guard let ref, let uid = ref.uid else { return }
            await withBackgroundTask(named: "cabal.push.markRead") { client in
                try await client.imapClient.setFlags(
                    folder: ref.folder,
                    uids: [uid],
                    flags: [.seen],
                    operation: .add
                )
            }
        case "ARCHIVE":
            guard let ref, let uid = ref.uid else { return }
            await withBackgroundTask(named: "cabal.push.archive") { [weak self] client in
                guard let destination = await self?.archiveFolderPath(using: client) else {
                    // No Archive folder on this account: creating one on
                    // demand is deliberately not this path's job, so the
                    // action degrades to a logged no-op.
                    CabalmailLog.warn("Push", "archive action skipped: no Archive folder")
                    return
                }
                try await client.imapClient.move(
                    folder: ref.folder,
                    uids: [uid],
                    destination: destination
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
    /// parks here and `sessionDidStart` re-routes it — `MailRootView`
    /// drains a pre-mount request from its `.task`.
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

    /// Resolves the archive destination: the cached path if the user has
    /// archived before, else the folder conventionally named "Archive".
    /// `LIST (SPECIAL-USE)` isn't exposed by the API-backed client, so the
    /// name is the best signal available; nil means "no archive folder".
    private func archiveFolderPath(using client: CabalmailClient) async -> String? {
        if let cached = UserDefaults.standard.string(forKey: Self.archiveFolderKey) {
            return cached
        }
        guard
            let folders = try? await client.imapClient.listFolders(),
            let archive = folders.first(where: {
                $0.path.caseInsensitiveCompare("Archive") == .orderedSame
            })
        else { return nil }
        UserDefaults.standard.set(archive.path, forKey: Self.archiveFolderKey)
        return archive.path
    }
}

// MARK: - Foreground enrichment workaround (macOS)

#if os(macOS)
extension PushRegistrar {
    /// Enriches a remote push while the app runs unfocused. macOS's
    /// notification daemon kills our Notification Service Extension before
    /// `didReceive` ever runs (the long-standing "sluggish startup" platform
    /// defect — Apple forums threads 693011 / 806789), so a remote push can
    /// only show the generic "New mail" once it leaves APNs. While the app
    /// itself is running it can do the NSE's job instead: fetch the envelope
    /// through the session client, post an enriched *local* notification,
    /// and let `willPresent` suppress the generic original. Returns false on
    /// any failure so the caller presents the original instead — a generic
    /// banner beats a silent drop. The NSE stays shipped as-is; if Apple
    /// fixes the platform it takes over the app-not-running case.
    func presentEnrichedNotification(for ref: PushMessageRef) async -> Bool {
        guard let client = await activeClient() else {
            CabalmailLog.warn("Push", "foreground enrichment skipped: no signed-in session")
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
            var msgRef: [String: Any] = ["folder": ref.folder]
            let resolvedUid = envelope.uid.flatMap { $0 == 0 ? nil : $0 } ?? ref.uid
            if let resolvedUid { msgRef["uid"] = Int(resolvedUid) }
            if let messageID = ref.messageID { msgRef["msg_id"] = messageID }
            content.userInfo = ["msgRef": msgRef]
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil
                )
            )
            return true
        } catch {
            CabalmailLog.warn("Push", "foreground enrichment failed: \(error)")
            return false
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

    /// The session client, or — on a cold background launch, where no scene
    /// ever attaches and `AppState.restoreIfPossible()` never runs — a
    /// client bootstrapped from the persisted control domain and keychain
    /// tokens. Auth refresh happens through the normal client path either
    /// way. Returns nil when signed out.
    private func activeClient() async -> CabalmailClient? {
        if let client { return client }
        let domain = UserDefaults.standard.string(forKey: "cabalmail.controlDomain") ?? ""
        guard !domain.isEmpty else { return nil }
        let store = AppState.makeSecureStore()
        guard (try? store.get(SecureStoreKey.authTokens)) != nil else { return nil }
        guard
            let configuration = try? await ConfigLoader.load(controlDomain: domain),
            let cacheDirectory = try? AppState.makeCacheDirectory(),
            let bootstrapped = try? CabalmailClient.make(
                configuration: configuration,
                secureStore: store,
                cacheDirectory: cacheDirectory
            )
        else { return nil }
        // Cache it: a burst of actions (several notifications triaged from
        // the lock screen) shouldn't rebuild the client per action. A later
        // sign-in replaces it via `sessionDidStart`.
        client = bootstrapped
        return bootstrapped
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
