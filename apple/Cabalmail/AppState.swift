import Foundation
import Observation
import UserNotifications
import CabalmailKit

/// Root observable state for the Cabalmail app.
///
/// SwiftUI views consume this via `.environment(...)`; mutations happen on
/// the main actor so view updates don't hop threads. Every network call it
/// fronts — Cognito, config.json, IMAP login — hops to the appropriate
/// actor (the client's, the transport's) and suspends back here for state
/// writes.
@Observable
@MainActor
final class AppState {
    enum Status: Sendable, Equatable {
        case signedOut
        case signingIn
        /// Launched with stored credentials; we're resolving whether they
        /// still work. The UI shows a splash rather than the sign-in form
        /// so the user doesn't see it flash for half a second on every
        /// launch.
        case restoring
        case signedIn
        case error(String)
    }

    var status: Status = .signedOut

    /// Ephemeral user-facing status message. Views render this as a floating
    /// banner and the owner clears it after a short interval. Phase 7's
    /// offline-send flow is the first consumer: when `CabalmailClient.send`
    /// returns `.queued`, the compose view sets this to
    /// "Message queued — will send when back online" so the user knows the
    /// message didn't silently vanish. Using a single shared slot (rather
    /// than a per-view toast subject) keeps state lifecycle simple and
    /// matches the React admin's `AppMessageContext`.
    var toast: Toast?

    /// Monotonic intent counters read by `MessageListView` /
    /// `MessageDetailView` via `.onChange`. macOS Commands menu actions
    /// (and Phase-7 keyboard shortcuts) bump these; consumers react to the
    /// value change and ignore the number itself. Using a plain `Int`
    /// instead of a PassthroughSubject keeps the surface `@Observable`-
    /// friendly without pulling in Combine.
    var composeRequestTick = 0
    var refreshRequestTick = 0
    /// Reply / reply-all / forward intent counters bumped from the macOS
    /// menu bar so the shortcut fires regardless of which scene holds
    /// AppKit first-responder focus. The currently-presented
    /// `MessageDetailView` observes them and runs `beginCompose(_:)` with
    /// the matching mode; when no detail view is on screen the bump is a
    /// no-op, which matches the user expectation that Reply without a
    /// selected message does nothing.
    var replyRequestTick = 0
    var replyAllRequestTick = 0
    var forwardRequestTick = 0

    /// Latest envelope disposed from the detail view. `MessageListView`
    /// observes this via `.onChange` and prunes the matching UID from its
    /// in-memory list so the moved message disappears immediately, without
    /// waiting for the next IDLE / pull-to-refresh. `tick` is monotonic so
    /// re-disposing the same UID (e.g. in a different folder) still fires
    /// the observer.
    var lastDisposedEnvelope: DisposedEnvelope?
    private var disposedTick = 0

    /// Latest envelope-flag change driven from the detail view (currently:
    /// `\Seen` toggles). `MessageListView` observes this so the row's bold
    /// styling and unread dot flip the moment the user taps "Mark as read"
    /// in the detail toolbar, without waiting for the next IDLE / pull-to-
    /// refresh. `tick` is monotonic so a revert (after a server error) still
    /// fires the observer when the same UID + flag flips back.
    var lastEnvelopeFlagChange: EnvelopeFlagChange?
    private var flagChangeTick = 0

    /// Authoritative Inbox unread count, refreshed by the badge poller.
    /// Exposed as an observable so future views (e.g. a sidebar indicator)
    /// can mirror what shows on the dock/home-screen badge.
    private(set) var inboxUnreadCount: Int = 0

    /// Per-folder unread counts. Authoritative writes land from
    /// `FolderListViewModel.refreshUnreadCounts` (via STATUS walk);
    /// optimistic deltas come from flag-change and dispose paths so the
    /// sidebar badges shift the moment the user acts, without waiting for
    /// the next STATUS round trip.
    private(set) var folderUnreadCounts: [String: Int] = [:]

    /// Replace the count for one folder. Called after an authoritative
    /// `STATUS (UNSEEN)`.
    func setUnreadCount(folderPath: String, count: Int) {
        folderUnreadCounts[folderPath] = max(0, count)
    }

    /// Replace the whole map. Used by the folder list view model after a
    /// full STATUS walk so any folders that have disappeared drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
    }

    /// Bump (or reduce) the count for one folder. Clamped at zero so a
    /// stale +1 from a doubled signal can't make the badge negative.
    func applyUnreadDelta(folderPath: String, delta: Int) {
        let current = folderUnreadCounts[folderPath] ?? 0
        folderUnreadCounts[folderPath] = max(0, current + delta)
    }
    private var inboxBadgeTask: Task<Void, Never>?
    private let inboxBadgePollInterval: UInt64 = 60 * 1_000_000_000

    func requestCompose() { composeRequestTick += 1 }
    func requestRefresh() { refreshRequestTick += 1 }
    func requestReply() { replyRequestTick += 1 }
    func requestReplyAll() { replyAllRequestTick += 1 }
    func requestForward() { forwardRequestTick += 1 }

    func signalDisposed(folderPath: String, uid: UInt32, wasUnread: Bool = false) {
        disposedTick += 1
        lastDisposedEnvelope = DisposedEnvelope(
            folderPath: folderPath,
            uid: uid,
            tick: disposedTick
        )
        // Dispose marks the message `\Seen` before the move, so the source
        // folder loses one unread message iff the row was unread to begin
        // with. The `setSeen(true)` path that ran moments earlier already
        // applied a -1 via `signalFlagChange`; passing `wasUnread` lets the
        // list-swipe path (which doesn't go through `setSeen`) report the
        // same delta exactly once.
        if wasUnread {
            applyUnreadDelta(folderPath: folderPath, delta: -1)
        }
    }

    func signalFlagChange(folderPath: String, uid: UInt32, flag: Flag, added: Bool) {
        flagChangeTick += 1
        lastEnvelopeFlagChange = EnvelopeFlagChange(
            folderPath: folderPath,
            uid: uid,
            flag: flag,
            added: added,
            tick: flagChangeTick
        )
        if flag == .seen {
            applyUnreadDelta(folderPath: folderPath, delta: added ? -1 : 1)
        }
    }

    /// Publishes a toast and auto-clears it after `duration`. The task lives
    /// outside structured concurrency because the caller's scope (usually a
    /// compose sheet) dismisses before the banner fades.
    func showToast(_ toast: Toast, duration: TimeInterval = 4) {
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self, self.toast == toast else { return }
            self.toast = nil
        }
    }

    /// Last-used control domain, persisted so repeat launches skip re-entry.
    var controlDomain: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.controlDomain") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabalmail.controlDomain") }
    }

    /// Last-used username, same persistence rationale. Passwords are never
    /// persisted here — `CognitoAuthService` holds them in the data-protection
    /// keychain via `KeychainSecureStore`.
    var lastUsername: String {
        get { UserDefaults.standard.string(forKey: "cabalmail.lastUsername") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cabalmail.lastUsername") }
    }

    private(set) var client: CabalmailClient?

    func signIn(controlDomain: String, username: String, password: String) async {
        status = .signingIn
        do {
            let configuration = try await ConfigLoader.load(controlDomain: controlDomain)
            let cacheDirectory = try makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: KeychainSecureStore(),
                cacheDirectory: cacheDirectory
            )
            try await newClient.authService.signIn(username: username, password: password)
            self.controlDomain = controlDomain
            self.lastUsername = username
            self.client = newClient
            self.status = .signedIn
            startInboxBadgePolling()
        } catch let error as CabalmailError {
            status = .error(message(for: error))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func signOut() async {
        stopInboxBadgePolling()
        guard let client else { status = .signedOut; return }
        await client.imapClient.disconnect()
        try? await client.authService.signOut()
        self.client = nil
        self.status = .signedOut
    }

    /// Launch-time auto-restore. Looks at the UserDefaults-persisted
    /// `controlDomain` + `lastUsername` and the Keychain-persisted Cognito
    /// tokens; if all three are present and the refresh token is still
    /// valid (or the ID token hasn't expired), transitions straight to
    /// `.signedIn` without prompting the user.
    ///
    /// Error handling mirrors the plan's cases:
    ///
    /// - Missing inputs (first launch, or post-signout) → silent signed-out.
    /// - Valid tokens → signed-in.
    /// - Refresh-token expired / revoked → clear the keychain so the sign-in
    ///   form starts clean, but keep `lastUsername` / `controlDomain` so
    ///   the form pre-fills.
    /// - Network / transport error → stay signed out *without* clearing
    ///   the keychain, so the next launch (or a manual sign-in) can
    ///   recover without forcing a password re-entry. This is the "airplane
    ///   mode at launch" path.
    /// - Any other error → `.error(message)`.
    ///
    /// Idempotent: if a client is already wired or sign-in is in flight,
    /// this is a no-op, so `.task` can call it without worrying about
    /// SwiftUI's lifecycle re-firing it.
    func restoreIfPossible() async {
        guard client == nil else { return }
        switch status {
        case .signingIn, .restoring, .signedIn:
            return
        default:
            break
        }
        let domain = controlDomain
        let username = lastUsername
        guard !domain.isEmpty, !username.isEmpty else {
            status = .signedOut
            return
        }
        let secureStore = KeychainSecureStore()
        guard (try? secureStore.get(SecureStoreKey.authTokens)) != nil else {
            status = .signedOut
            return
        }

        status = .restoring
        do {
            let configuration = try await ConfigLoader.load(controlDomain: domain)
            let cacheDirectory = try makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: secureStore,
                cacheDirectory: cacheDirectory
            )
            // Touching `currentIdToken()` validates the keychain contents:
            // a fresh ID token returns cached; an expired one triggers a
            // silent refresh; an expired / revoked refresh throws
            // `.authExpired` (Cognito's `NotAuthorizedException`).
            _ = try await newClient.authService.currentIdToken()
            self.client = newClient
            self.status = .signedIn
            startInboxBadgePolling()
        } catch let error as CabalmailError {
            switch error {
            case .authExpired, .invalidCredentials, .notSignedIn:
                // Refresh token is gone — clear the keychain so a stale
                // token doesn't keep tripping the sign-in form.
                try? secureStore.remove(SecureStoreKey.authTokens)
                try? secureStore.remove(SecureStoreKey.imapUsername)
                try? secureStore.remove(SecureStoreKey.imapPassword)
                status = .signedOut
            case .network, .transport, .timeout, .cancelled, .notConfigured:
                // Transient — leave the keychain alone. The sign-in form
                // will show but pre-filled, and a retry (or a later launch)
                // has a chance to recover without forcing the user to
                // re-enter their password.
                status = .signedOut
            default:
                status = .error(message(for: error))
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    /// Begin the Inbox-badge polling loop. Runs while signed in and polls
    /// `STATUS (UNSEEN)` on INBOX every 60 seconds, pushing the count to the
    /// system badge via `UNUserNotificationCenter`. Requests `.badge`
    /// authorization on first start — the system ignores repeat requests
    /// once the user has responded, so calling this on every sign-in is safe.
    /// Idempotent: subsequent calls while the task is running are no-ops.
    func startInboxBadgePolling() {
        guard inboxBadgeTask == nil, client != nil else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.badge])
        }
        let interval = inboxBadgePollInterval
        inboxBadgeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInboxUnread()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Tear down the badge poller and clear the system badge. Called on
    /// sign-out so the icon doesn't keep showing the last signed-in user's
    /// count. Idempotent — safe to call even if polling never started.
    func stopInboxBadgePolling() {
        inboxBadgeTask?.cancel()
        inboxBadgeTask = nil
        inboxUnreadCount = 0
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    private func refreshInboxUnread() async {
        guard let client else { return }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: "INBOX")
            let count = max(0, status.unseen ?? 0)
            inboxUnreadCount = count
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        } catch {
            // Best-effort: if the STATUS call fails (transient network
            // blip, IMAP reconnection) the prior badge value stays put
            // until the next poll succeeds.
        }
    }

    /// Returns the application-support cache directory for this app, creating
    /// it if needed. Per-folder subdirectories are created by the cache
    /// actors themselves.
    private func makeCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Cabalmail", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func message(for error: CabalmailError) -> String {
        // Most cases fall through to a canned or "prefix: detail" format;
        // split into two switches so neither exceeds the cyclomatic cap.
        if let canned = cannedMessage(for: error) { return canned }
        switch error {
        case .network(let detail):              return "Network error: \(detail)"
        case .transport(let detail):            return "Transport error: \(detail)"
        case .protocolError(let text):          return "Protocol error: \(text)"
        case .server(_, let text):              return "Server error: \(text)"
        case .decoding(let text):               return "Response error: \(text)"
        case .imapCommandFailed(_, let detail): return "IMAP: \(detail)"
        case .smtpCommandFailed(_, let detail): return "SMTP: \(detail)"
        default:                                return "\(error)"
        }
    }

    private func cannedMessage(for error: CabalmailError) -> String? {
        switch error {
        case .invalidCredentials: return "Incorrect username or password."
        case .notConfigured:      return "Control domain is invalid."
        case .authExpired:        return "Session expired. Please sign in again."
        case .timeout:            return "Request timed out."
        case .cancelled:          return "Cancelled."
        case .notSignedIn:        return "Not signed in."
        default:                  return nil
        }
    }
}
