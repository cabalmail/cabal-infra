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
        /// Password accepted; Cognito wants a second factor (identity plan
        /// Phase 1). `ContentView`'s default branch keeps rendering
        /// `SignInView`, which swaps in the code form for this status.
        case mfaCodeRequired(MfaMethod)
        /// Launched with stored credentials; we're resolving whether they
        /// still work. The UI shows a splash rather than the sign-in form
        /// so the user doesn't see it flash for half a second on every
        /// launch.
        case restoring
        case signedIn
        case error(String)
    }

    var status: Status = .signedOut

    /// Inline error for the second-factor form (wrong code, expired
    /// challenge). Kept separate from `Status.error` so a mistyped code
    /// doesn't bounce the user back to the password form.
    var mfaError: String?

    /// The client whose sign-in is paused at an MFA challenge, plus the
    /// context needed to finish it. Memory-only: a relaunch mid-challenge
    /// restarts the sign-in from the password form.
    private var pendingMfa: PendingMfaSignIn?

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
    /// Seed paired with the next compose-request tick. The mailto:
    /// URL handler stashes a pre-filled draft here before bumping
    /// `composeRequestTick`; the receiver (`ComposeRequestRouter` on
    /// `SignedInRootView`) reads and clears it when it opens the
    /// compose surface. Falls back to `ReplyBuilder.newDraft()` when
    /// nil. Cold launches that arrive via mailto leave the seed parked
    /// here until the signed-in root first appears — as does a mailto:
    /// that lands while an iPhone compose sheet is already up (drained
    /// when that sheet dismisses, so it never clobbers a draft).
    var pendingComposeSeed: Draft?
    /// Forwarded-message attachments awaiting pickup by the compose
    /// surface, keyed by seed draft id. The forward action stashes the
    /// original message's decoded attachments here — they're too big to
    /// ride the Codable `Draft` through `openWindow` — and `ComposeView`
    /// consumes them in its `.task`. In-memory only: like hand-picked
    /// compose attachments, they don't survive a relaunch or a resumed
    /// draft. `@ObservationIgnored` because no view renders this
    /// directly; it's a one-shot handoff, and consuming it during view
    /// setup must not invalidate anyone's body.
    @ObservationIgnored var pendingComposeAttachments: [UUID: [Attachment]] = [:]
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
    /// Selection-scoped message-action intents bumped from the shared
    /// Message menu (`MessageMenuCommands`: macOS menu bar, iPadOS
    /// hardware-keyboard menu). The on-screen `MessageListView` observes
    /// them and applies the action to its current selection; with nothing
    /// selected the bump is a no-op, matching the Reply convention above.
    var toggleSeenRequestTick = 0
    var toggleFlaggedRequestTick = 0
    var moveSelectionRequestTick = 0
    /// What those commands (and the reply family) currently have to act on,
    /// reported by the mail surface via `reportsMessageMenuAvailability`. The
    /// menu dims a command that would be a no-op instead of advertising it.
    var messageMenuAvailability: MessageMenuAvailability = .none
    /// Intent to open the iOS / iPadOS / visionOS settings sheet (General /
    /// Addresses / Folders). Bumped by the sidebar gear button and the ⌘,
    /// app command; `SignedInRootView` observes it and presents the sheet.
    /// macOS ignores it - settings there is the dedicated ⌘, scene.
    var settingsRequestTick = 0

    /// A Spotlight result tapped before sign-in / restore completed; routed
    /// once the session is wired, mirroring `PushRegistrar.pendingOpen`.
    /// `@ObservationIgnored` because no view renders it — it's a one-shot
    /// handoff consumed by `routePendingSpotlightOpen()` (SpotlightRouting).
    @ObservationIgnored var pendingSpotlightRef: SpotlightMessageRef?

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

    /// Latest mark-read-and-advance driven from the detail view's mark-read
    /// control. `MessageListView` observes this and moves the selection per
    /// the carried `MarkReadAdvance`; the `\Seen` flip itself travels on
    /// `lastEnvelopeFlagChange` as usual.
    var lastReadAdvanceRequest: ReadAdvanceRequest?
    private var readAdvanceTick = 0

    /// UIDs with a flag write in flight from the detail view, keyed by folder
    /// path (IMAP UIDs are only unique within a mailbox, so a bare UID set
    /// would let a pending write in one folder shield an unrelated row with
    /// the same UID in another). `MessageListViewModel.shieldFetched` reads
    /// this so a refresh that lands mid-write can't revert the detail view's
    /// optimistic flag - the cross-view analogue of the list's own
    /// `pendingFlagUIDs`. The detail view brackets each write via
    /// `setFlagWrite(folderPath:uid:inFlight:)`. Read directly at merge time
    /// (never from a view body), so observation tracking is irrelevant here.
    private(set) var pendingFlagWriteUIDs: [String: Set<UInt32>] = [:]

    /// UIDs the detail view has optimistically removed (archive / trash /
    /// move) but whose server move is still in flight, keyed by source folder
    /// path. The detail view prunes the list row up front via
    /// `signalDisposed`; without this `MessageListViewModel.shieldFetched`
    /// would let a refresh that lands before the move completes resurrect the
    /// row (the source folder still returns the UID). The cross-view analogue
    /// of the list's own `pendingRemovedUIDs`; bracketed via
    /// `setMoveInFlight(folderPath:uid:inFlight:)`. Folder-keyed for the same
    /// per-mailbox UID-uniqueness reason as `pendingFlagWriteUIDs`.
    private(set) var pendingMoveUIDs: [String: Set<UInt32>] = [:]

    /// True while a message-row drag is in flight on a wide-screen layout.
    /// `MailRootView`'s sidebar watches this to temporarily reveal the
    /// folder list as a drop target when the user is on the Addresses tab,
    /// flipping back when the drag ends. Driven through `beginMessageDrag()`
    /// / `endMessageDrag()` in the drag-and-drop extension below; internal
    /// (not `private(set)`) so those same-type extension methods can write it.
    var messageDragInProgress = false

    /// Latest drag-and-drop move. A folder row's drop handler posts this with
    /// the destination path; the active `MessageListView` observes it via
    /// `.onChange` and routes the payload through its view model so the move
    /// shares the optimistic-prune / unread-count / cache-cleanup path with
    /// the menu-driven and bulk moves.
    var pendingMoveRequest: MessageMoveRequest?
    // Internal so `requestMove` in the drag-and-drop extension below can bump it.
    var moveRequestTick = 0

    /// Authoritative Inbox unread count, refreshed by the badge poller.
    /// Exposed as an observable so future views (e.g. a sidebar indicator)
    /// can mirror what shows on the dock/home-screen badge.
    private(set) var inboxUnreadCount: Int = 0

    // Per-folder unread + total counts. The mutators that maintain these
    // maps live in the "Per-folder unread + total counts" extension below.
    var folderUnreadCounts: [String: Int] = [:]
    var folderTotalCounts: [String: Int] = [:]
    private var inboxBadgeTask: Task<Void, Never>?
    private let inboxBadgePollInterval: UInt64 = 60 * 1_000_000_000

    // `requestCompose(seed:)` and `consumePendingComposeSeed()` live in the
    // "Compose routing + onboarding" extension below, alongside the
    // contacts-access helper.
    func requestCompose() { composeRequestTick += 1 }
    func requestRefresh() { refreshRequestTick += 1 }
    func requestReply() { replyRequestTick += 1 }
    func requestReplyAll() { replyAllRequestTick += 1 }
    func requestForward() { forwardRequestTick += 1 }
    func requestSettings() { settingsRequestTick += 1 }
    // The selection-scoped request bumpers live in the "Message-menu
    // selection intents" extension below (SwiftLint type-body budget).

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

    func signalReadAdvance(folderPath: String, uid: UInt32, advance: MarkReadAdvance) {
        readAdvanceTick += 1
        lastReadAdvanceRequest = ReadAdvanceRequest(
            folderPath: folderPath,
            uid: uid,
            advance: advance,
            tick: readAdvanceTick
        )
    }

    /// Mark a detail-view flag write as in flight (`true`, when the STORE is
    /// dispatched) or resolved (`false`, on success or failure). While a UID
    /// is in flight the list's merge keeps the optimistic flag instead of the
    /// fetched one; clearing it lets the next refresh carry server truth. Safe
    /// to call `false` for a UID that was never inserted (a no-op removal).
    func setFlagWrite(folderPath: String, uid: UInt32, inFlight: Bool) {
        if inFlight {
            pendingFlagWriteUIDs[folderPath, default: []].insert(uid)
        } else {
            pendingFlagWriteUIDs[folderPath]?.remove(uid)
            if pendingFlagWriteUIDs[folderPath]?.isEmpty == true {
                pendingFlagWriteUIDs[folderPath] = nil
            }
        }
    }

    /// Mark a detail-view archive / trash / move as in flight (`true`, before
    /// the server move) or resolved (`false`, on success or failure). While a
    /// UID is in flight the list's merge keeps the optimistically-pruned row
    /// gone; clearing it lets the next refresh re-add the row if the move
    /// failed, or confirm its absence if it succeeded. Safe to call `false`
    /// for a UID that was never inserted (a no-op removal).
    func setMoveInFlight(folderPath: String, uid: UInt32, inFlight: Bool) {
        if inFlight {
            pendingMoveUIDs[folderPath, default: []].insert(uid)
        } else {
            pendingMoveUIDs[folderPath]?.remove(uid)
            if pendingMoveUIDs[folderPath]?.isEmpty == true {
                pendingMoveUIDs[folderPath] = nil
            }
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

    private(set) var client: CabalmailClient?

    /// Cross-client navigation cursor for the current session: remembers and
    /// restores the last folder/message and offers the cross-device jump.
    /// Wired alongside `client` on sign-in / restore, cleared on sign-out.
    private(set) var navCoordinator: NavStateCoordinator?

    /// Syncs app `Preferences` to the server so settings changed on one Apple
    /// client follow the Cabalmail account to another. Wired alongside `client`
    /// on sign-in / restore, cleared on sign-out.
    private(set) var prefsCoordinator: PreferencesSyncCoordinator?

    /// The app-root `Preferences` instance, handed in at launch by the app
    /// entry (`usePreferences(_:)`) so `wireSession` can start a
    /// `PreferencesSyncCoordinator` for it. Weak-by-convention: the app scene
    /// owns it for the whole process lifetime.
    private var preferences: Preferences?

    /// Local-only contacts lookup, used by message list / detail / avatar
    /// to enrich incoming mail with the user's own name and photo for the
    /// sender. One instance per app launch — the actor caches results for
    /// the session. No persisted state, no network round-trip; see
    /// `docs/0.9.x/apple-contacts-integration-plan.md`.
    let contactsStore: ContactsStore = LiveContactsStore()

    /// Session memo for sender-domain BIMI logo lookups, shared by the
    /// message list (an avatar per row, rows recycle on scroll) and the
    /// detail view. Collapses each domain to one `/fetch_bimi` round-trip
    /// per launch. One instance per app launch, like `contactsStore`.
    let bimiCache = BimiUrlCache()

    func signIn(controlDomain: String, username: String, password: String) async {
        status = .signingIn
        mfaError = nil
        pendingMfa = nil
        do {
            let configuration = try await ConfigLoader.load(controlDomain: controlDomain)
            let cacheDirectory = try Self.makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: Self.makeSecureStore(),
                cacheDirectory: cacheDirectory
            )
            let result = try await newClient.authService.signIn(username: username, password: password)
            if case .mfaCodeRequired(let method) = result {
                // Password accepted; tokens arrive only after the code.
                // Park the client and surface the code form.
                pendingMfa = PendingMfaSignIn(
                    client: newClient, controlDomain: controlDomain, username: username
                )
                status = .mfaCodeRequired(method)
                return
            }
            await completeInteractiveSignIn(
                client: newClient, controlDomain: controlDomain, username: username
            )
        } catch let error as CabalmailError {
            status = .error(message(for: error))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // `signOut()` lives in the "Session wiring" extension below, alongside
    // `wireSession` (SwiftLint type-body budget).

    /// Hands the app-root `Preferences` to `AppState` at launch, before any
    /// sign-in or restore, so `wireSession` can start a
    /// `PreferencesSyncCoordinator` for the signed-in user. Idempotent.
    func usePreferences(_ preferences: Preferences) {
        self.preferences = preferences
        // Pre-activate the persisted last session's account scope so the
        // launch UI (theme especially) renders from that account's cached
        // settings while `restoreIfPossible()` is still resolving over the
        // network. `wireSession` re-activates with the confirmed username;
        // for the normal restore path that's the same scope and a no-op.
        preferences.activate(controlDomain: controlDomain, username: lastUsername)
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
        let secureStore = Self.makeSecureStore()
        guard (try? secureStore.get(SecureStoreKey.authTokens)) != nil else {
            status = .signedOut
            return
        }

        status = .restoring
        do {
            let configuration = try await ConfigLoader.load(controlDomain: domain)
            let cacheDirectory = try Self.makeCacheDirectory()
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
            // Restore is the common launch path, so this is what keeps the
            // watch's session copy and the device's `/push_register` row
            // fresh across app launches (see `wireSession`).
            await wireSession(client: newClient, username: username)
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
        setInboxUnread(0)
    }

    private func refreshInboxUnread() async {
        guard let client else { return }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: "INBOX")
            setInboxUnread(status.unseen ?? 0)
        } catch {
            // Best-effort: if the STATUS call fails (transient network
            // blip, IMAP reconnection) the prior badge value stays put
            // until the next poll succeeds.
        }
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
        // Planned IMAP redeploy: show the API's friendly copy verbatim, no
        // "Server error:" prefix.
        case .maintenance(let message): return message
        // A Cognito trigger rejected the sign-in (e.g. the MFA-enrollment
        // gate). The Kit has already stripped Cognito's trigger wrapper;
        // what remains is the trigger's own user-facing copy, so show it
        // verbatim like .maintenance above.
        case .server(code: "UserLambdaValidationException", message: let message): return message
        default:                  return nil
        }
    }
}

// MARK: - Persisted last-session fields

extension AppState {
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
}

// MARK: - Session wiring

extension AppState {
    func signOut() async {
        stopInboxBadgePolling()
        guard let client else { status = .signedOut; return }
        #if os(iOS) || os(macOS)
        // Deregister the APNs token while the Cognito session still works —
        // `/push_deregister` is an authenticated call like every other, and
        // `authService.signOut()` below wipes the tokens.
        await PushRegistrar.shared.sessionWillEnd()
        #endif
        #if os(iOS)
        IntentBridge.shared.sessionWillEnd()
        #endif
        await client.imapClient.disconnect()
        // Wipe locally cached mail (envelopes, bodies, drafts, outbox) before
        // dropping the session so the next account to sign in on this device
        // can't read the previous user's messages from the shared on-disk
        // cache.
        await client.clearLocalData()
        try? await client.authService.signOut()
        // Tell the watch to drop its copy of the credentials too.
        WatchSessionBridge.shared.pushSignedOut()
        self.client = nil
        self.navCoordinator = nil
        self.prefsCoordinator?.stop()
        self.prefsCoordinator = nil
        self.status = .signedOut
    }

    /// Shared tail of `signIn` and `restoreIfPossible`: installs the client,
    /// flips to `.signedIn`, and kicks off the session-scoped side flows —
    /// badge polling, the contacts prompt, push registration (iOS/macOS),
    /// and the watch hand-off.
    private func wireSession(client newClient: CabalmailClient, username: String) async {
        self.client = newClient
        self.navCoordinator = NavStateCoordinator(client: newClient)
        if let preferences {
            // Swap the local settings cache to this account's scoped keys
            // before the server pull below: the previous account's values
            // (default From address included) must never carry over, even
            // when this account has no server copy yet or the pull fails
            // offline. No-op when the same account signs back in.
            preferences.activate(controlDomain: controlDomain, username: username)
            let coordinator = PreferencesSyncCoordinator(client: newClient, preferences: preferences)
            self.prefsCoordinator = coordinator
            // Non-blocking: the initial server pull (server wins on login)
            // shouldn't hold up the UI flipping to signed-in; the applied
            // values land a moment later.
            Task { await coordinator.start() }
        }
        self.status = .signedIn
        startInboxBadgePolling()
        requestContactsAccessIfNeeded()
        #if os(iOS) || os(macOS)
        // Runs on both entry paths, so every launch re-registers the APNs
        // token — `/push_register` upserts, making this a cheap refresh of
        // the row's `last_seen_at`.
        PushRegistrar.shared.sessionDidStart(appState: self, client: newClient)
        #endif
        #if os(iOS)
        // Hand the session to the App Intents bridge (replays a parked
        // OpenFolderIntent from a cold launch) and re-donate the
        // folder-parameterized App Shortcut phrases now that the folder
        // list is reachable.
        IntentBridge.shared.sessionDidStart(appState: self)
        CabalmailAppShortcuts.updateAppShortcutParameters()
        #endif
        // Refresh the on-device Spotlight index for this session (each
        // subscribed folder's top page), and route a Spotlight tap that
        // arrived before the session was wired (cold launch from search).
        Task { await newClient.refreshSpotlightIndex() }
        routePendingSpotlightOpen()
        await pushSessionToWatch(client: newClient, username: username)
    }
}

// MARK: - Client construction helpers

extension AppState {
    /// The keychain store the session client persists Cognito tokens
    /// through. On iOS and macOS it's wrapped in `PushMirroringSecureStore`
    /// so every token write — sign-in and each silent refresh — also lands
    /// in the shared containers the Notification Service Extension reads
    /// (see `PushEnrichmentStore`). Static (and non-private) so the push
    /// action-handler's cold-launch bootstrap builds an identical stack.
    static func makeSecureStore() -> SecureStore {
        #if os(iOS) || os(macOS)
        return PushMirroringSecureStore(base: KeychainSecureStore())
        #else
        return KeychainSecureStore()
        #endif
    }

    /// Returns the application-support cache directory for this app, creating
    /// it if needed. Per-folder subdirectories are created by the cache
    /// actors themselves. Static for the same bootstrap reason as
    /// `makeSecureStore`.
    static func makeCacheDirectory() throws -> URL {
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
}

// MARK: - Watch hand-off

extension AppState {
    /// Hands the signed-in session (configuration + Cognito tokens) to the
    /// paired watch. `WatchSessionBridge` is a no-op stub on platforms
    /// without WatchConnectivity, so callers don't need platform guards.
    private func pushSessionToWatch(client: CabalmailClient, username: String) async {
        guard let tokens = await client.authService.currentTokens() else { return }
        WatchSessionBridge.shared.pushSession(
            configuration: client.configuration,
            tokens: tokens,
            username: username
        )
    }

    /// Re-offers the current session to the watch. Called on every return
    /// to the foreground: the watch's "open Cabalmail on your iPhone"
    /// instruction has to work when the app was *already running* — the
    /// launch-time push has long since fired by then, and
    /// `restoreIfPossible()` is deliberately a no-op while signed in, so
    /// without this the instruction only worked after a cold start.
    func refreshWatchSession() async {
        guard let client else { return }
        await pushSessionToWatch(client: client, username: lastUsername)
    }
}

// MARK: - Message-menu selection intents

// Bumpers for the selection-scoped tick counters declared on the main
// type (stored properties can't live in an extension under @Observable).
extension AppState {
    func requestToggleSeen() { toggleSeenRequestTick += 1 }
    func requestToggleFlagged() { toggleFlaggedRequestTick += 1 }
    func requestMoveSelection() { moveSelectionRequestTick += 1 }
}

// MARK: - Per-folder unread + total counts
//
// Mutators for the `folderUnreadCounts` / `folderTotalCounts` storage declared
// on the main type above. Subscribed folders' counts get refreshed proactively
// by `FolderListViewModel`; unsubscribed folders are populated lazily on
// selection, and the unsubscribed-folder banner's Refresh button writes the
// freshest values through `setFolderCounts` so the sidebar badge and the
// message-list view advance together. Kept as a same-file extension so the
// primary class body stays under SwiftLint's `type_body_length` cap.
@MainActor
extension AppState {
    /// Replace the unread count for one folder. Called after an
    /// authoritative `STATUS (UNSEEN)` when the caller doesn't have the
    /// total in hand (e.g. an optimistic delta-based recovery path).
    func setUnreadCount(folderPath: String, count: Int) {
        folderUnreadCounts[folderPath] = max(0, count)
    }

    /// Replace the unread + total counts for one folder in one shot.
    /// Preferred over `setUnreadCount` whenever a full STATUS reply is
    /// in hand, so the two maps don't drift.
    func setFolderCounts(folderPath: String, unread: Int, total: Int) {
        folderUnreadCounts[folderPath] = max(0, unread)
        folderTotalCounts[folderPath] = max(0, total)
        if Self.isInbox(folderPath) { setInboxUnread(unread) }
    }

    /// Replace the whole unread map. Used by the folder list view model
    /// after a full STATUS walk so any folders that have disappeared
    /// drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
        if let inbox = counts.first(where: { Self.isInbox($0.key) })?.value {
            setInboxUnread(inbox)
        }
    }

    /// Bump (or reduce) the count for one folder. Clamped at zero so a
    /// stale +1 from a doubled signal can't make the badge negative.
    func applyUnreadDelta(folderPath: String, delta: Int) {
        let current = folderUnreadCounts[folderPath] ?? 0
        folderUnreadCounts[folderPath] = max(0, current + delta)
        // Keep the icon badge live. It reads `inboxUnreadCount`, which the
        // 60s poller refreshes from server STATUS — but that poll can't run
        // while the app is backgrounded, so an archive done just before
        // backgrounding used to leave the badge showing the pre-archive
        // count. Applying the same delta here updates the badge the instant
        // the action lands; the poller stays the authority that reconciles
        // any drift on the next foreground.
        if Self.isInbox(folderPath) { setInboxUnread(inboxUnreadCount + delta) }
    }

    /// Canonical INBOX match — IMAP's INBOX name is case-insensitive
    /// (RFC 3501), and folder paths reach these mutators verbatim from the
    /// server, so compare case-insensitively rather than against a literal.
    static func isInbox(_ folderPath: String) -> Bool {
        folderPath.caseInsensitiveCompare("INBOX") == .orderedSame
    }

    /// Single chokepoint for the Inbox unread count and the system icon
    /// badge. Every writer — the STATUS poller, optimistic archive/mark-read
    /// deltas, and full STATUS walks — routes through here so the two never
    /// diverge. The badge task re-reads `inboxUnreadCount` at execution time
    /// rather than capturing `count`, so a burst of deltas can't land the
    /// badge on a stale intermediate value if the tasks run out of order.
    func setInboxUnread(_ count: Int) {
        inboxUnreadCount = max(0, count)
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(inboxUnreadCount)
        }
    }
}

// MARK: - Compose routing + onboarding
//
// The compose-seed helpers (`requestCompose(seed:)` /
// `consumePendingComposeSeed`) plumb a pre-filled draft from the `mailto:`
// URL handler through to `MessageListView`'s receiver without bypassing the
// existing `composeRequestTick` mechanism that macOS menu shortcuts already
// use. The contacts-access helper kicks off the system permission prompt
// during sign-in / restore.
@MainActor
extension AppState {
    /// Variant of `requestCompose` that pairs an explicit seed with
    /// the request. Used by the mailto: URL handler and by every
    /// view-level compose entry point (toolbar New Message, reply /
    /// forward, resume draft); the macOS Commands menu still calls the
    /// zero-arg form, which leaves `pendingComposeSeed` nil and lets
    /// the receiver fall back to a fresh draft.
    func requestCompose(seed: Draft) {
        pendingComposeSeed = seed
        composeRequestTick += 1
    }

    /// Reads and clears the pending compose seed. Called by the
    /// compose-request receiver (`ComposeRequestRouter`) on
    /// `.onChange(of: composeRequestTick)` (warm path), on its initial
    /// `.task` (cold-launch mailto: arrived before the signed-in root
    /// was in the hierarchy), and on compose-sheet dismissal (a
    /// mailto: that arrived while a draft was open stays parked until
    /// the draft closes).
    func consumePendingComposeSeed() -> Draft? {
        defer { pendingComposeSeed = nil }
        return pendingComposeSeed
    }

    /// Stash the original message's attachments for a forward seed. The
    /// compose surface picks them up via `consumeComposeAttachments(for:)`.
    func stashComposeAttachments(_ attachments: [Attachment], for draftId: UUID) {
        pendingComposeAttachments[draftId] = attachments
    }

    /// Reads and clears the stashed attachments for one compose seed.
    /// Pop-once, so a system-restored compose scene (whose stashed bytes
    /// are gone) degrades to composing without them rather than stalling.
    func consumeComposeAttachments(for draftId: UUID) -> [Attachment] {
        defer { pendingComposeAttachments[draftId] = nil }
        return pendingComposeAttachments[draftId] ?? []
    }

    /// Kick off a one-shot contacts authorization request,
    /// fire-and-forget. `CNContactStore.requestAccess` no-ops after
    /// the user has already responded, so calling this on every
    /// sign-in / restore is harmless. We prompt at sign-in (rather
    /// than lazily on first compose / message open) so the request
    /// lands while the user is already in onboarding mode and the
    /// message list that immediately follows shows hydrated names
    /// from the first paint.
    func requestContactsAccessIfNeeded() {
        let store = contactsStore
        Task {
            _ = await store.requestAccess()
        }
    }
}

// MARK: - Drag-and-drop coordination
//
// Mutators for the `messageDragInProgress` / `pendingMoveRequest` /
// `moveRequestTick` storage declared on the main type above. The drag flag
// and the move request are the two halves of moving a message onto a sidebar
// folder: the flag lets the sidebar reveal folders mid-drag (see
// `MailRootView`), and the move request hands the dropped payload to the
// active message list (see `MessageListView`). See
// `Cabalmail/Views/MessageDrag.swift` for the drag/drop plumbing itself.
@MainActor
extension AppState {
    /// Drag lifecycle, driven from SwiftUI drag/drop closures. `begin` fires
    /// when a row is lifted; `end` fires on drop or release. Both are
    /// idempotent so the burst of drag callbacks the system can emit doesn't
    /// matter.
    func beginMessageDrag() { messageDragInProgress = true }
    func endMessageDrag() { messageDragInProgress = false }

    /// Post a drag-and-drop move for the active message list to perform.
    /// `tick` is monotonic so dragging onto the same folder twice still fires
    /// the list's `.onChange` observer.
    func requestMove(items: [MessageDragItem], to destination: String) {
        moveRequestTick += 1
        pendingMoveRequest = MessageMoveRequest(
            destination: destination,
            items: items,
            tick: moveRequestTick
        )
    }
}

/// Sign-in paused at a second-factor challenge (identity plan Phase 1).
/// Promoted out of `AppState` like `Toast`, and a struct rather than a
/// tuple to satisfy SwiftLint's `large_tuple` cap.
private struct PendingMfaSignIn {
    let client: CabalmailClient
    let controlDomain: String
    let username: String
}

// MARK: - Second-factor sign-in

extension AppState {
    /// Finishes the second-factor step started by `signIn`. Success runs the
    /// same session wiring as a challenge-free sign-in; a wrong code stays
    /// on the code form (Cognito allows a bounded number of retries against
    /// the same challenge session); an expired challenge falls back to the
    /// password form.
    func submitMfaCode(_ code: String) async {
        guard case .mfaCodeRequired(let method) = status, let pending = pendingMfa else {
            status = .signedOut
            return
        }
        mfaError = nil
        do {
            try await pending.client.authService.submitMfaCode(code)
            let ctx = pending
            pendingMfa = nil
            await completeInteractiveSignIn(
                client: ctx.client, controlDomain: ctx.controlDomain, username: ctx.username
            )
        } catch let error as CabalmailError {
            if case .server(let code, _) = error, code == "CodeMismatchException" {
                status = .mfaCodeRequired(method)
                mfaError = "That code did not match. Please try again."
                return
            }
            // Anything else (challenge session expired, throttled, ...)
            // restarts from the password form with the standard message.
            pendingMfa = nil
            status = .error(message(for: error))
        } catch {
            pendingMfa = nil
            status = .error(error.localizedDescription)
        }
    }

    /// Abandons a pending second-factor challenge and returns to the
    /// password form.
    func cancelMfaChallenge() {
        pendingMfa = nil
        mfaError = nil
        status = .signedOut
    }

    /// Shared tail of `signIn` and `submitMfaCode` once tokens exist.
    func completeInteractiveSignIn(
        client newClient: CabalmailClient, controlDomain: String, username: String
    ) async {
        // Defense in depth for the force-kill path: a clean sign-out wipes
        // the shared on-disk cache, but a hard quit doesn't. If a different
        // account just signed in on this device, clear the prior user's
        // cached mail before the new session populates it.
        if !lastUsername.isEmpty, lastUsername != username {
            await newClient.clearLocalData()
        }
        self.controlDomain = controlDomain
        self.lastUsername = username
        await wireSession(client: newClient, username: username)
    }
}
