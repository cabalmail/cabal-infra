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
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .badge, .sound]
            )) ?? false
            guard granted else { return }
            Platform.registerForRemoteNotifications()
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
    /// system re-delivers it) and whenever APNs rotates it.
    func deviceTokenDidChange(_ tokenHex: String) {
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
            locale: Locale.current.identifier
        )
        Task {
            do {
                try await client.apiClient.registerPushDevice(registration)
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
