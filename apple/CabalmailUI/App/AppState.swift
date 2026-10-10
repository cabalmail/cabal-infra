import Foundation
import Observation
import CabalmailKit

/// Root observable state for the Cabalmail app.
///
/// SwiftUI views consume this via `.environment(...)`; mutations happen on
/// the main actor so view updates don't hop threads. The session lifecycle
/// (sign-in, restore, sign-out, the session's client) lives on
/// `sessionManager`, which this forwards to; what a session's start and end
/// do to the state held here runs through the hooks `init` installs on it.
@Observable
@MainActor
public final class AppState {
    public typealias Status = SessionManager.Status

    /// The session lifecycle and what lives with a session. One per
    /// `AppState`: the app entries make it before any scene and also hand it
    /// to the push and intent paths, which borrow its client.
    let sessionManager: SessionManager

    // The session surface views and menus read, forwarded so they keep
    // reading it here. Observation follows the reads into the manager.
    public var status: Status { sessionManager.status }
    /// Why the sign-in form is showing when the user did not ask for it
    /// (`SessionManager.signedOutReason`, issue #1703).
    var signedOutReason: SignedOutReason? { sessionManager.signedOutReason }
    /// Inline error for the second-factor form.
    var mfaError: String? { sessionManager.mfaError }
    public var client: CabalmailClient? { sessionManager.client }
    /// Cross-client navigation cursor for the current session.
    public var navCoordinator: NavStateCoordinator? { sessionManager.navCoordinator }
    /// Syncs app `Preferences` to the server for the signed-in account.
    public var prefsCoordinator: PreferencesSyncCoordinator? { sessionManager.prefsCoordinator }
    /// The last control domain and username signed in, persisted.
    var controlDomain: String { sessionManager.controlDomain }
    var lastUsername: String { sessionManager.lastUsername }

    /// Ephemeral user-facing status message. Views render this as a floating
    /// banner and the owner clears it after a short interval. Phase 7's
    /// offline-send flow is the first consumer: when `CabalmailClient.send`
    /// returns `.queued`, the compose view sets this to
    /// "Message queued — will send when back online" so the user knows the
    /// message didn't silently vanish. Using a single shared slot (rather
    /// than a per-view toast subject) keeps state lifecycle simple and
    /// matches the React admin's `AppMessageContext`.
    var toast: Toast?

    /// Window identities for the compose scene group, recycled rather
    /// than minted per session (issue #1084). Lives on `AppState` because
    /// the compose scene itself reads it, and the coordinator below hands
    /// its slots out. `@ObservationIgnored` because the registry is its
    /// own observable; the reference never changes.
    @ObservationIgnored public let composeSlots: ComposeSlotRegistry
    /// Where a compose request goes: one main window's compose surface
    /// (`ComposeCoordinator`). It holds the seeds waiting for a window that
    /// cannot show them yet, and a forward's attachments until its composer
    /// takes them. `@ObservationIgnored`: no view observes it.
    @ObservationIgnored public let compose: ComposeCoordinator
    /// The main window most recently in front, for a mailto: link, and for
    /// a compose window that closes. Observed by each main window too:
    /// the window it names records the place the app resumes from, and
    /// records its own place when it becomes the one named
    /// (`WindowRecorder`).
    public var lastActiveMainWindow: UUID?

    /// Bumped each time this process forgets an account (a Sign Out, an
    /// expiry, a sign-out during the launch restore), so every mounted main
    /// window clears the route its scene stores (`StoredRoute`).
    private(set) var accountForgottenTick = 0

    /// Where a notification, a Spotlight result or Siri's Open Folder opens:
    /// one main window (`DeepLinkRouter`). The app entries' state takes the
    /// app's router; `AppState()` makes its own.
    @ObservationIgnored let deepLinks: DeepLinkRouter

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

    public convenience init() {
        self.init(sessionManager: SessionManager(), deepLinks: DeepLinkRouter())
    }

    /// The app entries' init: `sessionManager` is the one they also hand to
    /// `PushRegistrar` and `IntentBridge`, and `deepLinks` the router those
    /// open links through.
    public init(sessionManager: SessionManager, deepLinks: DeepLinkRouter = .shared) {
        self.sessionManager = sessionManager
        self.deepLinks = deepLinks
        let slots = ComposeSlotRegistry()
        composeSlots = slots
        compose = ComposeCoordinator(slots: slots)
        mailStore = MailSessionStore(teardownGate: sessionManager.teardownGate)
        // The badge poller's count is bounded by the writes it may predate.
        sessionManager.pollers.boundInboxUnread = { [weak self] count, askedAt in
            self?.mailStore.polledInboxUnread(count, askedAt: askedAt) ?? count
        }
        sessionManager.owner = sessionOwnerHooks()
        deepLinks.appState = self
    }
}

// MARK: - Session entry points

extension AppState {
    func signIn(controlDomain: String, username: String, password: String) async {
        await sessionManager.signIn(controlDomain: controlDomain, username: username, password: password)
    }

    func submitMfaCode(_ code: String) async {
        await sessionManager.submitMfaCode(code)
    }

    func cancelMfaChallenge() {
        sessionManager.cancelMfaChallenge()
    }

    func signOut() async {
        await sessionManager.signOut()
    }

    /// Launch-time auto-restore (`SessionManager.restoreIfPossible()`); a
    /// no-op once signed in, so a re-firing `.task` stays cheap.
    public func restoreIfPossible() async {
        await sessionManager.restoreIfPossible()
    }

    /// Hands the app-root `Preferences` to the session lifecycle at launch,
    /// before any sign-in or restore. Idempotent.
    public func usePreferences(_ preferences: Preferences) {
        sessionManager.usePreferences(preferences)
    }

    /// Re-offers the current session to the watch; called on every return to
    /// the foreground (`SessionManager.refreshWatchSession()`).
    public func refreshWatchSession() async {
        await sessionManager.refreshWatchSession()
    }
}

// MARK: - What a session does to this state

extension AppState {
    /// The hooks `init` installs on the session manager, each run where it
    /// always ran in the session's wiring or teardown.
    private func sessionOwnerHooks() -> SessionOwnerHooks {
        SessionOwnerHooks(
            appState: { [weak self] in self },
            clientInstalled: { [weak self] client in
                self?.mailStore.counts.savedFolderCounts.cache = client.folderStateCache
            },
            requestContactsAccess: { [weak self] in self?.requestContactsAccessIfNeeded() },
            accountChanged: { [weak self] in self?.deepLinks.discardParked() },
            inboxUnreadChanged: { [weak self] in self?.mailStore.counts.setInboxUnread($0) },
            forgetAccount: { [weak self] in self?.forgetAccountState() },
            clientDropped: { [weak self] in self?.endClientSession() }
        )
    }

    /// What this process knows about the account, with or without a client:
    /// the next account must start from none of it (#1825). The mail store
    /// is reset in place (`MailSessionStore.forgetAccount()`); what it keeps
    /// across sessions, and why, is said there.
    private func forgetAccountState() {
        accountForgottenTick += 1
        mailStore.forgetAccount()
        deepLinks.discardParked()
        AttachmentFolders.removeAll()
    }

    /// Run in the same turn as the session manager drops the client, so no
    /// closed compose window builds a composer for the next session in
    /// between.
    private func endClientSession() {
        composeSlots.endSession()
    }
}

// MARK: - Onboarding
//
// The contacts-access helper kicks off the system permission prompt during
// sign-in / restore.
@MainActor
extension AppState {
    /// Kick off a one-shot contacts authorization request,
    /// fire-and-forget. `CNContactStore.requestAccess` no-ops after
    /// the user has already responded, so calling this on every
    /// sign-in / restore is harmless. We prompt at sign-in (rather
    /// than lazily on first compose / message open) so the request
    /// lands while the user is already in onboarding mode and the
    /// message list that immediately follows shows hydrated names
    /// from the first paint.
    func requestContactsAccessIfNeeded() {
        sessionManager.sessionEnvironment.hooks.requestContactsAccess(contactsStore)
    }
}

// MARK: - Drag-and-drop coordination
//
// Mutators for the `pendingMoveRequest` / `moveRequestTick` storage declared
// on the main type above: the move request hands a payload dropped on a
// sidebar folder to the active message list (see `MessageListView`). See
// `CabalmailUI/Mail/MessageDrag.swift` for the drag/drop plumbing itself.
@MainActor
extension AppState {
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
