import Foundation
import Observation
import CabalmailKit

/// Owns the session lifecycle: sign-in and its second factor, the launch
/// restore, sign-out, and what lives and dies with a session — its client,
/// the navigation cursor, the preferences sync, the expiry observer and the
/// two pollers. Every network call it fronts (Cognito, config.json) hops to
/// the client's or the transport's actor and suspends back here for state
/// writes.
///
/// One client per account: the background paths (a notification action, an
/// App Intent, the macOS silent-push enrichment) borrow the session's client
/// through `borrowClient()` instead of building their own, so one send queue
/// drains the outbox and one observer hears an expiry.
///
/// `AppState` holds one and forwards its session surface here. What a
/// session's start and end do to `AppState`'s own state runs through
/// `SessionOwnerHooks`, which `AppState` installs in its init. The app
/// entries make one before any scene and hand the same one to `AppState`,
/// `PushRegistrar` and `IntentBridge`; `AppState()` makes its own.
@Observable
@MainActor
public final class SessionManager {
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

    public internal(set) var status: Status = .signedOut

    /// Why the app is showing the sign-in form when the user did not ask for
    /// it. `nil` after a deliberate Sign Out (and at a first launch), set when
    /// a session is torn down under the user — on the launch path by
    /// `restore()`'s expiry branch, and while the app is running by
    /// `handleSessionExpiry()`. `SignInView` renders it so a blank form never
    /// leaves the user guessing why they are back here (issue #1703).
    var signedOutReason: SignedOutReason?

    /// Inline error for the second-factor form (wrong code, expired
    /// challenge). Kept separate from `Status.error` so a mistyped code
    /// doesn't bounce the user back to the password form.
    var mfaError: String?

    /// The session's client, from the moment the session is wired until
    /// sign-out drops it.
    public private(set) var client: CabalmailClient?

    /// Cross-client navigation cursor for the current session: remembers and
    /// restores the last folder/message and offers the cross-device jump.
    /// Wired alongside `client` on sign-in / restore, cleared on sign-out.
    public private(set) var navCoordinator: NavStateCoordinator?

    /// Syncs app `Preferences` to the server so settings changed on one Apple
    /// client follow the Cabalmail account to another. Wired alongside `client`
    /// on sign-in / restore, cleared on sign-out.
    public private(set) var prefsCoordinator: PreferencesSyncCoordinator?

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
    /// Shared with `AppState.mailStore`, whose `acceptsCounts(from:)` answers
    /// from the sessions this records as ended.
    @ObservationIgnored let teardownGate = SessionTeardownGate()

    /// What a session's start and end do to `AppState`'s own state, installed
    /// by `AppState.init`.
    @ObservationIgnored var owner = SessionOwnerHooks()

    /// The Inbox badge and feed refresh loops, running while signed in.
    @ObservationIgnored let pollers = SessionPollers()

    /// The client whose sign-in is paused at an MFA challenge, plus the
    /// context needed to finish it. Memory-only: a relaunch mid-challenge
    /// restarts the sign-in from the password form.
    private var pendingMfa: PendingMfaSignIn?

    /// The app-root `Preferences` instance, handed in at launch by the app
    /// entry (`usePreferences(_:)`) so `wireSession` can start a
    /// `PreferencesSyncCoordinator` for it. Weak-by-convention: the app scene
    /// owns it for the whole process lifetime.
    private var preferences: Preferences?

    /// The stored account's client while no session is wired, built by
    /// whichever of a borrower and the launch restore asked first, lent to
    /// every borrower, and adopted by the restore. Let go when a session is
    /// wired or ends.
    @ObservationIgnored private var standby: CabalmailClient?

    /// The build of `standby` in flight; whoever else asks for it waits on
    /// this build instead of starting another.
    @ObservationIgnored private var standbyBuild: StandbyBuild?

    /// The client of the second-factor submit in flight, which a cancel
    /// meanwhile must not shut down: the submit may still wire it.
    @ObservationIgnored private var mfaSubmitting: CabalmailClient?

    public init() {
        pollers.client = { [weak self] in self?.client }
        pollers.inboxUnreadChanged = { [weak self] in self?.owner.inboxUnreadChanged($0) }
    }

    func signIn(controlDomain: String, username: String, password: String) async {
        await teardownGate.awaitTeardown()
        status = .signingIn
        mfaError = nil
        abandonPendingMfa()
        // The explanation has been read by the time the user is typing.
        signedOutReason = nil
        var built: CabalmailClient?
        do {
            // The cache is seeded here so a launch with no network right
            // after this sign-in can still restore (see `restoreIfPossible`).
            let configuration = try await sessionEnvironment.loadConfiguration(controlDomain)
            let newClient = try sessionEnvironment.makeClient(
                configuration, sessionEnvironment.makeSecureStore(), sessionInvalidation
            )
            built = newClient
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
            letGo(of: built)
            status = .error(SignInErrorText.message(for: error))
        } catch {
            letGo(of: built)
            status = .error(error.localizedDescription)
        }
    }

    /// Hands the app-root `Preferences` to the session lifecycle at launch,
    /// before any sign-in or restore, so `wireSession` can start a
    /// `PreferencesSyncCoordinator` for the signed-in user. Idempotent.
    func usePreferences(_ preferences: Preferences) {
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
    /// A client a borrower already built for the stored account is the one
    /// this restore wires; a borrower that asks while this restore builds
    /// it waits for the same build (`storedAccountClient`).
    ///
    /// Idempotent: if a client is already wired or sign-in is in flight,
    /// this is a no-op, so `.task` can call it without worrying about
    /// SwiftUI's lifecycle re-firing it.
    func restoreIfPossible() async {
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
            let newClient = try await storedAccountClient(
                domain: domain, secureStore: secureStore, forRestore: true
            )
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
        // The restore built (or adopted) the stored account's client and is
        // not wiring it, so nothing lends it any more.
        if let built, standby === built { standby = nil }
        letGo(of: built)
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
}

// MARK: - Session wiring

extension SessionManager {
    /// Ends the session. One teardown at a time: a second call waits for the
    /// first, and a restore in flight finishes first (`SessionTeardownGate`).
    func signOut() async {
        await teardownGate.signOut { [self] in await tearDownSession() }
    }

    private func tearDownSession() async {
        pollers.stopInboxBadgePolling()
        pollers.stopFeedRefreshPolling()
        sessionExpiryTask?.cancel()
        sessionExpiryTask = nil
        // A deliberate sign-out is its own explanation; `handleSessionExpiry`
        // re-sets this after calling through here.
        signedOutReason = nil
        // Before the reset, so a count this session's work fetches from here
        // on is dropped rather than written back over it (#1848).
        if let client { teardownGate.markEnded(client) }
        owner.forgetAccount()
        // Whatever was lent goes with the session, wired or not.
        letGo(of: takeStandby())
        guard let client else {
            status = .signedOut
            return
        }
        await endSession(of: client, cursor: navCoordinator)
        // Same turn as dropping the client, so no closed compose window
        // builds a composer for the next session in between.
        owner.clientDropped()
        self.client = nil
        self.navCoordinator = nil
        self.prefsCoordinator?.stop()
        self.prefsCoordinator = nil
        self.status = .signedOut
        // After every state write: what the client still runs on its own
        // stops, and nothing about the session changes while it does.
        await client.shutdown()
    }

    /// Shared tail of `signIn` and `restoreIfPossible`: installs the client,
    /// flips to `.signedIn`, and kicks off the session-scoped side flows —
    /// badge polling, the contacts prompt, push registration (iOS/macOS),
    /// and the watch hand-off.
    private func wireSession(client newClient: CabalmailClient, username: String) async {
        // A sign-in over a wired session (#1826) replaces its client.
        let replaced = client
        self.client = newClient
        if let standby = takeStandby(), standby !== newClient { letGo(of: standby) }
        owner.clientInstalled(newClient)
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
        pollers.startInboxBadgePolling(requestAuthorization: sessionEnvironment.hooks.requestBadgeAuthorization)
        owner.requestContactsAccess()
        // Push registration, the Intents bridge and App Shortcut phrases.
        if let appState = owner.appState() {
            sessionEnvironment.hooks.sessionDidStart(appState, newClient)
        }
        // Refresh the on-device Spotlight index for this session (each
        // subscribed folder's top page). A Spotlight tap that arrived before
        // the session was wired waits in `DeepLinkRouter` for the first
        // window to open.
        Task { await newClient.refreshSpotlightIndex() }
        // Feed reader (RSS plan, phase 5): the first pass pulls the catalog
        // and every subscription's new items so the Feeds section is current
        // before the user opens it; then every fifteen minutes.
        pollers.startFeedRefreshPolling()
        if let replaced, replaced !== newClient { letGo(of: replaced) }
        await pushSessionToWatch(client: newClient, username: username)
    }
}

// MARK: - Lending the client

extension SessionManager {
    /// The client background work borrows: a notification action, an App
    /// Intent, the macOS silent-push enrichment. With a session, its client.
    /// Without one, the stored account's, built once through the restore's
    /// environment (the cached config.json, the keychain, the expiry
    /// monitor) without wiring a session, and adopted by the next restore.
    /// Nil when no account is stored, or when the session the build was for
    /// ended while it ran. Throws what building it threw.
    public func borrowClient() async throws -> CabalmailClient? {
        if let client { return client }
        let domain = controlDomain
        let username = lastUsername
        guard !domain.isEmpty, !username.isEmpty else { return nil }
        let secureStore = sessionEnvironment.makeSecureStore()
        guard (try? secureStore.get(SecureStoreKey.authTokens)) != nil else { return nil }
        let lent = try await storedAccountClient(domain: domain, secureStore: secureStore)
        // A session wired while the build ran lends its own client; one that
        // ended took the build with it.
        if let client { return client }
        return standby === lent ? lent : nil
    }

    /// The stored account's client while no session is wired: `standby`, or
    /// one build of it shared by whoever asks while it runs. A build is lent
    /// only if it finishes with no session wired and no sign-out since it
    /// started. Otherwise it is let go, unless a restore took part in it:
    /// the restore still decides, wiring it or ending the session it built
    /// (#1827), as it did with a client it built alone.
    private func storedAccountClient(
        domain: String, secureStore: SecureStore, forRestore: Bool = false
    ) async throws -> CabalmailClient {
        if let standby { return standby }
        if standbyBuild != nil {
            if forRestore { standbyBuild?.restoreTookPart = true }
            return try await withCheckedThrowingContinuation { standbyBuild?.waiters.append($0) }
        }
        standbyBuild = StandbyBuild(restoreTookPart: forRestore)
        let generation = teardownGate.generation
        do {
            let configuration = try await sessionEnvironment.loadConfiguration(domain)
            let built = try sessionEnvironment.makeClient(configuration, secureStore, sessionInvalidation)
            let build = finishStandbyBuild(.success(built))
            if teardownGate.generation == generation, client == nil {
                standby = built
            } else if !build.restoreTookPart {
                letGo(of: built)
            }
            return built
        } catch {
            finishStandbyBuild(.failure(error))
            throw error
        }
    }

    /// Ends the build in flight, resuming whoever waited on it.
    @discardableResult
    private func finishStandbyBuild(_ result: Result<CabalmailClient, Error>) -> StandbyBuild {
        let build = standbyBuild ?? StandbyBuild(restoreTookPart: false)
        standbyBuild = nil
        for waiter in build.waiters {
            waiter.resume(with: result)
        }
        return build
    }

    /// Takes `standby` out of the lending slot, for the caller to wire or
    /// let go of.
    private func takeStandby() -> CabalmailClient? {
        defer { standby = nil }
        return standby
    }

    /// A client the manager no longer holds stops what it runs on its own:
    /// its send queue and its Spotlight feed. Its API calls and caches keep
    /// working for anyone still holding it, but a count fetched through it
    /// is no longer written: a lent client let go because another account
    /// signed in, or at a sign-out with no session wired, is marked ended
    /// like a session's (#1892). Never the wired client or the one being
    /// lent.
    private func letGo(of dropped: CabalmailClient?) {
        guard let dropped, dropped !== client, dropped !== standby else { return }
        teardownGate.markEnded(dropped)
        Task { await dropped.shutdown() }
    }
}

// MARK: - Session expiry and the end of a session

extension SessionManager {
    /// Watch for this install's credentials being refused, for the life of
    /// the session. Replaces any previous observer, so signing back in does
    /// not leave two running. Called from `wireSession`, which is the one
    /// place both entry paths (sign-in, restore) pass through.
    ///
    /// Subscribes here, not inside the task. The task's body waits for the
    /// main actor's next turn — at launch that can be long enough for a
    /// restore's first call to die of the refresh — and the monitor has no
    /// replay, so a signal in that gap found no listener and the app stayed
    /// signed in. Registered now, it is buffered until the loop drains it.
    func observeSessionInvalidation() {
        sessionExpiryTask?.cancel()
        let events = sessionInvalidation.events()
        sessionExpiryTask = Task { [weak self] in
            for await _ in events {
                await self?.handleSessionExpiry()
            }
        }
    }

    /// Drop a session the server has stopped honouring, while the app is up.
    ///
    /// Before this existed, an expiry mid-session only ever became the *text*
    /// of whichever call happened to fail: the app stayed in the mail shell
    /// serving cached content and Settings ▸ Account still read "Signed in",
    /// because `restore()` was the only code that translated an expired
    /// session into a status change (issue #1703). Routed through `signOut()`
    /// so there is exactly one teardown rather than two that can drift — the
    /// difference is the reason, which the sign-in form then explains.
    ///
    /// Acts only on a live session (#1826): the Kit announces once per
    /// invalidation, but a signal that lands after the user has already
    /// signed out must not put "your session expired" on a form they asked
    /// for, and from any other state there is no session to expire. A
    /// teardown already running ends the session anyway. The reason is set
    /// only if nothing has moved the status on since, and no Sign Out the
    /// user chose joined the teardown (#1829).
    func handleSessionExpiry() async {
        guard status == .signedIn, !teardownGate.isTearingDown else { return }
        let requests = teardownGate.signOutRequests
        await signOut()
        guard status == .signedOut, teardownGate.signOutRequests == requests + 1 else { return }
        signedOutReason = .sessionExpired
    }

    /// The part of a sign-out that needs the session's client, in order: push
    /// deregistration and the Intents bridge while the Cognito session still
    /// works (`authService.signOut()` wipes the tokens), the per-feed site
    /// data, the cached mail, the tokens, the watch's copy and the resume
    /// state. Also ends a session a restore built but did not wire.
    func endSession(of client: CabalmailClient, cursor: NavStateCoordinator?) async {
        await sessionEnvironment.hooks.sessionWillEnd()
        // Per-feed site data (publisher logins) lives in WebKit, out of the
        // Kit's reach: drop it while the feed store still knows the stores.
        FeedWebStorage.drop(uuids: (try? await client.rssStore?.allDataStoreUuids()) ?? [])
        // Wipe locally cached mail (envelopes, bodies, drafts, outbox) before
        // dropping the session so the next account to sign in on this device
        // can't read the previous user's messages from the shared on-disk
        // cache. The feed store is closed too, so a feed sync still running
        // for this session can't write it back (#1937).
        await client.clearLocalDataEndingSession()
        try? await client.authService.signOut()
        // Tell the watch to drop its copy of the credentials too.
        sessionEnvironment.hooks.sessionDidEnd()
        // Forget this install's resume session and reading positions too, so
        // the next account on the device doesn't inherit them.
        cursor?.clearLocalState()
    }

    /// Ends a session the launch restore built but never wired, because the
    /// user signed out while it was being built (#1827). Its cursor is built
    /// only to clear the resume state this launch would have restored. The
    /// client was the stored account's, so the lending slot lets it go too.
    func endUnwiredSession(_ client: CabalmailClient) async {
        if standby === client { standby = nil }
        await endSession(of: client, cursor: sessionEnvironment.makeNavCoordinator(client))
        await client.shutdown()
    }

    /// Removes a stored session's tokens and IMAP credentials without a
    /// client: what restore does when Cognito refuses the refresh.
    static func removeStoredSession(from secureStore: SecureStore) {
        try? secureStore.remove(SecureStoreKey.authTokens)
        try? secureStore.remove(SecureStoreKey.imapUsername)
        try? secureStore.remove(SecureStoreKey.imapPassword)
    }
}

// MARK: - Watch hand-off

extension SessionManager {
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
    func refreshWatchSession() async {
        guard let client else { return }
        await pushSessionToWatch(client: client, username: lastUsername)
    }
}

/// A build of the stored account's client in flight (`storedAccountClient`).
private struct StandbyBuild {
    var waiters: [CheckedContinuation<CabalmailClient, Error>] = []
    /// A launch restore started or joined it, and will wire it or end it.
    var restoreTookPart: Bool
}

/// Sign-in paused at a second-factor challenge (identity plan Phase 1).
/// A struct rather than a tuple to satisfy SwiftLint's `large_tuple` cap.
private struct PendingMfaSignIn {
    let client: CabalmailClient
    let controlDomain: String
    let username: String
}

// MARK: - Second-factor sign-in

extension SessionManager {
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
        mfaSubmitting = pending.client
        do {
            try await pending.client.authService.submitMfaCode(code)
            mfaSubmitting = nil
            let ctx = pending
            pendingMfa = nil
            await completeInteractiveSignIn(
                client: ctx.client, controlDomain: ctx.controlDomain, username: ctx.username
            )
        } catch let error as CabalmailError {
            mfaSubmitting = nil
            if case .server(let code, _) = error, code == "CodeMismatchException" {
                // A challenge abandoned while the code was checked is not
                // coming back for this client.
                if pendingMfa?.client !== pending.client { letGo(of: pending.client) }
                status = .mfaCodeRequired(method)
                mfaError = "That code did not match. Please try again."
                return
            }
            // Anything else (challenge session expired, throttled, ...)
            // restarts from the password form with the standard message.
            abandonSubmittedMfa(pending.client)
            status = .error(SignInErrorText.message(for: error))
        } catch {
            mfaSubmitting = nil
            abandonSubmittedMfa(pending.client)
            status = .error(error.localizedDescription)
        }
    }

    /// Abandons a pending second-factor challenge and returns to the
    /// password form. A no-op off the code form, where it would show the
    /// password form over whatever is there (#1826).
    func cancelMfaChallenge() {
        guard case .mfaCodeRequired = status else { return }
        abandonPendingMfa()
        mfaError = nil
        status = .signedOut
    }

    /// Lets the parked challenge's client go, unless a code submitted on it
    /// is still being checked: that submit may yet wire it, and lets it go
    /// itself if it fails.
    private func abandonPendingMfa() {
        if let parked = pendingMfa?.client, parked !== mfaSubmitting { letGo(of: parked) }
        pendingMfa = nil
    }

    /// A failed submit's client goes, whether or not it is still parked.
    private func abandonSubmittedMfa(_ submitted: CabalmailClient) {
        if pendingMfa?.client === submitted { pendingMfa = nil }
        letGo(of: submitted)
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
            owner.accountChanged()
        }
        self.controlDomain = controlDomain
        self.lastUsername = username
        await wireSession(client: newClient, username: username)
    }
}

// MARK: - Persisted last-session fields

extension SessionManager {
    /// Last-used control domain, persisted so repeat launches skip re-entry.
    /// Mirrored into the shared App Group for the embedded Safari web
    /// extension, which asks its native handler for it so the user never
    /// types the server twice (ExtensionControlDomainStore).
    var controlDomain: String {
        get { sessionEnvironment.lastSessionDefaults.string(forKey: "cabalmail.controlDomain") ?? "" }
        set {
            sessionEnvironment.lastSessionDefaults.set(newValue, forKey: "cabalmail.controlDomain")
            sessionEnvironment.publishControlDomain(newValue)
        }
    }

    /// Last-used username, same persistence rationale. Passwords are never
    /// persisted here — `CognitoAuthService` holds them in the data-protection
    /// keychain via `KeychainSecureStore`.
    var lastUsername: String {
        get { sessionEnvironment.lastSessionDefaults.string(forKey: "cabalmail.lastUsername") ?? "" }
        set { sessionEnvironment.lastSessionDefaults.set(newValue, forKey: "cabalmail.lastUsername") }
    }
}
