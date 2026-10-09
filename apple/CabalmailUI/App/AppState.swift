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
    /// compose or Settings window is key. Observed by each main window too:
    /// the window it names records the place the app resumes from, and
    /// records its own place when it becomes the one named
    /// (`WindowRecorder`).
    public var lastActiveMainWindow: UUID?

    /// Bumped each time this process forgets an account (a Sign Out, an
    /// expiry, a sign-out during the launch restore), so every mounted main
    /// window clears the route its scene stores (`StoredRoute`).
    private(set) var accountForgottenTick = 0

    /// A Spotlight result tapped before sign-in / restore completed; routed
    /// once the session is wired, mirroring `PushRegistrar.pendingOpen`.
    /// `@ObservationIgnored` because no view renders it — it's a one-shot
    /// handoff consumed by `routePendingSpotlightOpen()` (SpotlightRouting).
    @ObservationIgnored var pendingSpotlightRef: SpotlightMessageRef?

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
        self.init(sessionManager: SessionManager())
    }

    /// The app entries' init: `sessionManager` is the one they also hand to
    /// `PushRegistrar` and `IntentBridge`.
    public init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        mailStore = MailSessionStore(teardownGate: sessionManager.teardownGate)
        // The badge poller's count is bounded by the writes it may predate.
        sessionManager.pollers.boundInboxUnread = { [weak self] count, askedAt in
            self?.mailStore.polledInboxUnread(count, askedAt: askedAt) ?? count
        }
        sessionManager.owner = sessionOwnerHooks()
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
            routeParkedOpens: { [weak self] in self?.routePendingSpotlightOpen() },
            accountChanged: { [weak self] in self?.pendingSpotlightRef = nil },
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
        pendingSpotlightRef = nil
        AttachmentFolders.removeAll()
    }

    /// Run in the same turn as the session manager drops the client, so no
    /// closed compose window builds a composer for the next session in
    /// between.
    private func endClientSession() {
        composeSlots.endSession()
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
