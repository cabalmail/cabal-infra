import Foundation
import Observation
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
public final class AppState {
    public enum Status: Sendable, Equatable {
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

    public var status: Status = .signedOut

    /// Why the app is showing the sign-in form when the user did not ask for
    /// it. `nil` after a deliberate Sign Out (and at a first launch), set when
    /// a session is torn down under the user — on the launch path by
    /// `restore()`'s expiry branch, and while the app is running by
    /// `handleSessionExpiry()`. `SignInView` renders it so a blank form never
    /// leaves the user guessing why they are back here (issue #1703).
    var signedOutReason: SignedOutReason?

    /// Announced by the Kit when this install's credentials stop working
    /// (issue #1703). Process-scoped rather than per-session: it is handed to
    /// every client `make(...)` builds, so a signal from a client that is
    /// about to be dropped still reaches the observer.
    @ObservationIgnored let sessionInvalidation = SessionInvalidationMonitor()

    /// What the session lifecycle reaches outside the process; `.live`
    /// everywhere but the app-layer tests (see `SessionEnvironment`).
    @ObservationIgnored var sessionEnvironment = SessionEnvironment.live

    /// Observes `sessionInvalidation` for the life of a session. One observer
    /// is what covers every call site: each view model keeps rendering its own
    /// error text, and the teardown happens here exactly once.
    @ObservationIgnored var sessionExpiryTask: Task<Void, Never>?

    /// Orders sign-out against sign-in and the launch restore (#1827, #1829).
    /// Shared with `mailStore`, whose `acceptsCounts(from:)` answers from the
    /// sessions this records as ended.
    @ObservationIgnored let teardownGate: SessionTeardownGate

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
    /// Window identities for the compose scene group, recycled rather
    /// than minted per session (issue #1084). Lives on `AppState` because
    /// all three compose entry points — the request router, the compose
    /// scene itself, and the macOS menu-bar extra — already read it.
    /// `@ObservationIgnored` because the registry is its own observable;
    /// the reference never changes.
    @ObservationIgnored public let composeSlots = ComposeSlotRegistry()
    /// Forwarded-message attachments awaiting pickup by the compose
    /// surface, keyed by seed draft id. The forward action stashes the
    /// original message's decoded attachments here rather than on the
    /// seed itself — and `ComposeView` consumes them in its `.task`. In-memory only: like hand-picked
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
    /// Mailbox ▸ Mark All as Read (⌥⌘T). The on-screen folder-scoped
    /// `MessageListView` observes it and stages its confirmation; nothing
    /// answers on the search surface, which is why the menu dims there.
    var markFolderReadRequestTick = 0
    /// Which section is in front of the user — the mail list or the feed
    /// reader — so the Message/Mailbox and Feeds menus, which share chords
    /// (⌘T, ⌘⇧8, ⌥⌘T), are never both enabled. Reported by the layout that
    /// knows: `MailRootView` on the wide layouts (feed scope selected or
    /// not), the section tabs on compact and visionOS. See
    /// `SharedChordPolicy`.
    public var activeSection: ResumeSession.Section = .mail
    /// What the Feeds menu's item commands have to act on, reported by the
    /// surface that owns the feed scope and item selection
    /// (`reportsFeedMenuAvailability`); the feed twin of
    /// `messageMenuAvailability`.
    var feedMenuAvailability: FeedMenuAvailability = .none
    /// What those commands (and the reply family) currently have to act on,
    /// reported by the mail surface via `reportsMessageMenuAvailability`. The
    /// menu dims a command that would be a no-op instead of advertising it.
    var messageMenuAvailability: MessageMenuAvailability = .none
    /// What the macOS `Mailbox` menu can act on, reported by the mail surfaces
    /// themselves. Separate from `messageMenuAvailability` because it answers a
    /// different question — "is a list on screen at all", not "what is
    /// selected" — and Refresh is dead in a state where the whole selection
    /// question is moot (#1162).
    public var mailboxMenuAvailability: MailboxMenuAvailability = .none
    /// Intent to open the iOS / iPadOS / visionOS settings sheet (General /
    /// Addresses / Folders). Bumped by the sidebar gear button and the ⌘,
    /// app command; `SignedInRootView` observes it and presents the sheet.
    /// macOS ignores it - settings there is the dedicated ⌘, scene.
    var settingsRequestTick = 0
    /// Feeds menu intents (RSS plan, phase 5c): the menu names the command
    /// and bumps the tick; the mounted feed sidebar answers through
    /// `FeedManagementSheets`. See `requestFeedCommand` in `AppState+Feeds`.
    var feedCommandTick = 0
    /// Expand all / Collapse all for the sidebar trees, from the Mailbox and
    /// Feeds menus. The mounted sidebar that owns the named tree applies it
    /// (`FolderListView` for mail and, on the wide layouts, feeds;
    /// `FeedSidebarList` for the compact Feeds tab). See
    /// `requestSidebarTree(_:)`.
    var sidebarTreeCommandTick = 0
    var pendingSidebarTreeCommand: SidebarTreeCommand?
    var pendingFeedCommand: FeedCommand?
    /// The main window the latest command tick is aimed at; nil reaches
    /// every window. Set with each tick by the `request…` methods and read
    /// by the observers when the tick fires (`AppStateSignals.swift`).
    @ObservationIgnored var commandWindow: UUID?
    /// The main window most recently in front, for commands issued while a
    /// compose or Settings window is key.
    @ObservationIgnored public var lastActiveMainWindow: UUID?

    /// A Spotlight result tapped before sign-in / restore completed; routed
    /// once the session is wired, mirroring `PushRegistrar.pendingOpen`.
    /// `@ObservationIgnored` because no view renders it — it's a one-shot
    /// handoff consumed by `routePendingSpotlightOpen()` (SpotlightRouting).
    @ObservationIgnored var pendingSpotlightRef: SpotlightMessageRef?

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

    /// The mail state the folder list, message list, reader and composer
    /// share (`MailSessionStore`): the folder counts, the shields that keep
    /// a refresh from undoing a write in flight, and the signals the reader
    /// and composer send the list. One for the life of
    /// this `AppState`, reset in place at sign-out (`forgetAccountState`).
    /// A `let`, so nothing observes the reference; views observe the
    /// store's own properties through it.
    public let mailStore: MailSessionStore
    private var inboxBadgeTask: Task<Void, Never>?
    private let inboxBadgePollInterval: UInt64 = 60 * 1_000_000_000
    // Feed reader poller; the methods live in `AppState+Feeds.swift`.
    var feedRefreshTask: Task<Void, Never>?
    let feedRefreshInterval: UInt64 = 15 * 60 * 1_000_000_000

    // `requestCompose(seed:)` and `consumePendingComposeSeed()` live in the
    // "Compose routing + onboarding" extension below, alongside the
    // contacts-access helper.
    // `window` names the main window the command is for; nil reaches every
    // window (see `AppStateSignals.swift`).
    func requestCompose(in window: UUID? = nil) { commandWindow = window; composeRequestTick += 1 }
    public func requestRefresh(in window: UUID? = nil) { commandWindow = window; refreshRequestTick += 1 }
    func requestReply(in window: UUID? = nil) { commandWindow = window; replyRequestTick += 1 }
    func requestReplyAll(in window: UUID? = nil) { commandWindow = window; replyAllRequestTick += 1 }
    func requestForward(in window: UUID? = nil) { commandWindow = window; forwardRequestTick += 1 }
    public func requestSettings(in window: UUID? = nil) { commandWindow = window; settingsRequestTick += 1 }
    // The selection-scoped request bumpers live in the "Message-menu
    // selection intents" extension in `AppStateSignals.swift` (SwiftLint
    // type-body budget).

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

    public private(set) var client: CabalmailClient?
    /// The one search model both iOS layout trees share — see
    /// `sharedSearchModel(client:preferences:)` in `AppState+Search.swift`.
    var searchModelStore: MessageListViewModel?

    /// Cross-client navigation cursor for the current session: remembers and
    /// restores the last folder/message and offers the cross-device jump.
    /// Wired alongside `client` on sign-in / restore, cleared on sign-out.
    public private(set) var navCoordinator: NavStateCoordinator?

    /// Syncs app `Preferences` to the server so settings changed on one Apple
    /// client follow the Cabalmail account to another. Wired alongside `client`
    /// on sign-in / restore, cleared on sign-out.
    public private(set) var prefsCoordinator: PreferencesSyncCoordinator?

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
        await teardownGate.awaitTeardown()
        status = .signingIn
        mfaError = nil
        pendingMfa = nil
        // The explanation has been read by the time the user is typing.
        signedOutReason = nil
        do {
            // The cache is seeded here so a launch with no network right
            // after this sign-in can still restore (see `restoreIfPossible`).
            let configuration = try await sessionEnvironment.loadConfiguration(controlDomain)
            let newClient = try sessionEnvironment.makeClient(
                configuration, sessionEnvironment.makeSecureStore(), sessionInvalidation
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
            status = .error(SignInErrorText.message(for: error))
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    public init() {
        let teardownGate = SessionTeardownGate()
        self.teardownGate = teardownGate
        mailStore = MailSessionStore(teardownGate: teardownGate)
    }

    // `signOut()` lives in the "Session wiring" extension below, alongside
    // `wireSession` (SwiftLint type-body budget).

    /// Hands the app-root `Preferences` to `AppState` at launch, before any
    /// sign-in or restore, so `wireSession` can start a
    /// `PreferencesSyncCoordinator` for the signed-in user. Idempotent.
    public func usePreferences(_ preferences: Preferences) {
        self.preferences = preferences
        // Pre-activate the persisted last session's account scope so the
        // launch UI (theme especially) renders from that account's cached
        // settings while `restoreIfPossible()` is still resolving over the
        // network. `wireSession` re-activates with the confirmed username;
        // for the normal restore path that's the same scope and a no-op.
        preferences.activate(controlDomain: controlDomain, username: lastUsername)
        // Existing installs signed in long ago and the setter above never
        // re-fires for them; re-publish at launch so the embedded Safari
        // extension learns the domain without a fresh sign-in.
        sessionEnvironment.publishControlDomain(controlDomain)
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
    /// - Network / transport error → the "airplane mode at launch" path.
    ///   `config.json` comes from the last good copy, and a token refresh
    ///   that can't reach Cognito still wires the session, so cached mail
    ///   is readable offline. Only with no cached config (never fetched on
    ///   this install) does it stay signed out, *without* clearing the
    ///   keychain, so a later launch or a manual sign-in can recover
    ///   without forcing a password re-entry.
    /// - Any other error → `.error(message)`.
    ///
    /// Idempotent: if a client is already wired or sign-in is in flight,
    /// this is a no-op, so `.task` can call it without worrying about
    /// SwiftUI's lifecycle re-firing it.
    public func restoreIfPossible() async {
        await teardownGate.awaitTeardown()
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
        let secureStore = sessionEnvironment.makeSecureStore()
        guard (try? secureStore.get(SecureStoreKey.authTokens)) != nil else {
            status = .signedOut
            return
        }

        status = .restoring
        let generation = teardownGate.beginRestore()
        defer { teardownGate.endRestore() }
        var built: CabalmailClient?
        do {
            // Offline, the last good config.json stands in for the fetch so
            // the cached mail, Outbox and feeds stay reachable at launch.
            let configuration = try await sessionEnvironment.loadConfiguration(domain)
            let newClient = try sessionEnvironment.makeClient(configuration, secureStore, sessionInvalidation)
            built = newClient
            // Validates the keychain contents: a fresh ID token passes; an
            // expired one triggers a silent refresh; an expired / revoked
            // refresh throws `.authExpired` (Cognito's
            // `NotAuthorizedException`). A refresh that can't reach Cognito,
            // or that Cognito throttles, passes, so cached mail is readable
            // offline.
            try await OfflineLaunch.validateStoredSession(newClient.authService)
            // A sign-out meanwhile is waiting for this restore to finish:
            // end the session it asked to end rather than wire it (#1827).
            guard teardownGate.generation == generation else {
                await endUnwiredSession(newClient)
                return
            }
            // Restore is the common launch path, so this is what keeps the
            // watch's session copy and the device's `/push_register` row
            // fresh across app launches (see `wireSession`).
            await wireSession(client: newClient, username: username)
        } catch {
            let signedOut = teardownGate.generation != generation
            await restoreFailed(error, client: built, secureStore: secureStore, signedOut: signedOut)
        }
    }

    /// The catch arms of `restoreIfPossible`. `signedOut`: a sign-out came
    /// in while the restore ran and is waiting for it, so its failure no
    /// longer decides anything; what the sign-out would have removed goes.
    private func restoreFailed(
        _ error: Error, client built: CabalmailClient?, secureStore: SecureStore, signedOut: Bool
    ) async {
        if signedOut {
            if let built {
                await endUnwiredSession(built)
            } else {
                Self.removeStoredSession(from: secureStore)
            }
            return
        }
        guard let error = error as? CabalmailError else {
            status = .error(error.localizedDescription)
            return
        }
        switch error {
        case .authExpired, .invalidCredentials, .notSignedIn:
            // Refresh token is gone — clear the keychain so a stale
            // token doesn't keep tripping the sign-in form.
            Self.removeStoredSession(from: secureStore)
            signedOutReason = .sessionExpired
            status = .signedOut
        case .network, .transport, .cancelled, .notConfigured:
            // Transient — leave the keychain alone. The sign-in form
            // will show but pre-filled, and a retry (or a later launch)
            // has a chance to recover without forcing the user to
            // re-enter their password.
            status = .signedOut
        default:
            status = .error(SignInErrorText.message(for: error))
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
        sessionEnvironment.hooks.requestBadgeAuthorization()
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
        mailStore.counts.setInboxUnread(0)
    }

    private func refreshInboxUnread() async {
        guard let client else { return }
        do {
            let status = try await client.folderStatus(path: "INBOX")
            mailStore.counts.setInboxUnread(status.unseen ?? 0)
        } catch {
            // Best-effort: if the STATUS call fails (transient network
            // blip, IMAP reconnection) the prior badge value stays put
            // until the next poll succeeds.
        }
    }
}

// MARK: - Session wiring

extension AppState {
    /// Ends the session. One teardown at a time: a second call waits for the
    /// first, and a restore in flight finishes first (`SessionTeardownGate`).
    func signOut() async {
        await teardownGate.signOut { [self] in await tearDownSession() }
    }

    private func tearDownSession() async {
        stopInboxBadgePolling()
        stopFeedRefreshPolling()
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        // A deliberate sign-out is its own explanation; `handleSessionExpiry`
        // re-sets this after calling through here.
        signedOutReason = nil
        // Before the reset, so a count this session's work fetches from here
        // on is dropped rather than written back over it (#1848).
        if let client { teardownGate.markEnded(client) }
        forgetAccountState()
        guard let client else { status = .signedOut; return }
        await endSession(of: client, cursor: navCoordinator)
        // Same turn as dropping the client, so no closed compose window
        // builds a composer for the next session in between.
        composeSlots.endSession()
        self.client = nil
        self.navCoordinator = nil
        self.searchModelStore = nil
        self.prefsCoordinator?.stop()
        self.prefsCoordinator = nil
        self.status = .signedOut
    }

    /// What this process knows about the account, with or without a client:
    /// the next account must start from none of it (#1825). The mail store
    /// is reset in place (`MailSessionStore.forgetAccount()`); what it keeps
    /// across sessions, and why, is said there.
    private func forgetAccountState() {
        mailStore.forgetAccount()
        pendingSpotlightRef = nil
        AttachmentFolders.removeAll()
    }

    /// Shared tail of `signIn` and `restoreIfPossible`: installs the client,
    /// flips to `.signedIn`, and kicks off the session-scoped side flows —
    /// badge polling, the contacts prompt, push registration (iOS/macOS),
    /// and the watch hand-off.
    private func wireSession(client newClient: CabalmailClient, username: String) async {
        self.client = newClient
        mailStore.counts.savedFolderCounts.cache = newClient.folderStateCache
        self.navCoordinator = sessionEnvironment.makeNavCoordinator(newClient)
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
        observeSessionInvalidation()
        self.status = .signedIn
        startInboxBadgePolling()
        requestContactsAccessIfNeeded()
        // Push registration, the Intents bridge and App Shortcut phrases.
        sessionEnvironment.hooks.sessionDidStart(self, newClient)
        // Refresh the on-device Spotlight index for this session (each
        // subscribed folder's top page), and route a Spotlight tap that
        // arrived before the session was wired (cold launch from search).
        Task { await newClient.refreshSpotlightIndex() }
        routePendingSpotlightOpen()
        // Feed reader (RSS plan, phase 5): the first pass pulls the catalog
        // and every subscription's new items so the Feeds section is current
        // before the user opens it; then every fifteen minutes.
        startFeedRefreshPolling()
        await pushSessionToWatch(client: newClient, username: username)
    }
}

// MARK: - Watch hand-off

extension AppState {
    /// Hands the signed-in session (configuration + Cognito tokens) to the
    /// paired watch. `WatchSessionBridge` is a no-op stub on platforms
    /// without WatchConnectivity, so callers don't need platform guards.
    private func pushSessionToWatch(client: CabalmailClient, username: String) async {
        guard let tokens = await client.authService.currentTokens() else { return }
        sessionEnvironment.hooks.pushSessionToWatch(client.configuration, tokens, username)
    }

    /// Re-offers the current session to the watch. Called on every return
    /// to the foreground: the watch's "open Cabalmail on your iPhone"
    /// instruction has to work when the app was *already running* — the
    /// launch-time push has long since fired by then, and
    /// `restoreIfPossible()` is deliberately a no-op while signed in, so
    /// without this the instruction only worked after a cold start.
    public func refreshWatchSession() async {
        guard let client else { return }
        await pushSessionToWatch(client: client, username: lastUsername)
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
    public func requestCompose(seed: Draft, in window: UUID? = nil) {
        pendingComposeSeed = seed
        commandWindow = window
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
        sessionEnvironment.hooks.requestContactsAccess(contactsStore)
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
// `CabalmailUI/Mail/MessageDrag.swift` for the drag/drop plumbing itself.
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
    /// `sourceList` names the message list the drag lifted from, which is
    /// the one list that performs the move.
    func requestMove(items: [MessageDragItem], to destination: String, from sourceList: UUID?) {
        moveRequestTick += 1
        pendingMoveRequest = MessageMoveRequest(
            destination: destination,
            items: items,
            sourceList: sourceList,
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
    /// password form. Only the code form submits: in any other state there is
    /// no challenge, and a session may be wired (#1826).
    func submitMfaCode(_ code: String) async {
        guard case .mfaCodeRequired(let method) = status else { return }
        guard let pending = pendingMfa else {
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
            status = .error(SignInErrorText.message(for: error))
        } catch {
            pendingMfa = nil
            status = .error(error.localizedDescription)
        }
    }

    /// Abandons a pending second-factor challenge and returns to the
    /// password form. A no-op off the code form, where it would show the
    /// password form over whatever is there (#1826).
    func cancelMfaChallenge() {
        guard case .mfaCodeRequired = status else { return }
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
            // A Spotlight result parked while signed out was indexed for the
            // last account (#1825).
            pendingSpotlightRef = nil
        }
        self.controlDomain = controlDomain
        self.lastUsername = username
        await wireSession(client: newClient, username: username)
    }
}
