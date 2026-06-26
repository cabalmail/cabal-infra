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
    /// Seed paired with the next compose-request tick. The mailto:
    /// URL handler stashes a pre-filled draft here before bumping
    /// `composeRequestTick`; the receiver in `MessageListView` reads
    /// and clears it when it opens the compose surface. Falls back to
    /// `ReplyBuilder.newDraft()` when nil. Cold launches that arrive
    /// via mailto leave the seed parked here until `MessageListView`
    /// first appears.
    var pendingComposeSeed: Draft?
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
    /// Intent to open the iOS / iPadOS / visionOS settings sheet (General /
    /// Addresses / Folders). Bumped by the sidebar gear button and the ⌘,
    /// app command; `SignedInRootView` observes it and presents the sheet.
    /// macOS ignores it - settings there is the dedicated ⌘, scene.
    var settingsRequestTick = 0

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
        do {
            let configuration = try await ConfigLoader.load(controlDomain: controlDomain)
            let cacheDirectory = try makeCacheDirectory()
            let newClient = try CabalmailClient.make(
                configuration: configuration,
                secureStore: KeychainSecureStore(),
                cacheDirectory: cacheDirectory
            )
            try await newClient.authService.signIn(username: username, password: password)
            // Defense in depth for the force-kill path: a clean sign-out wipes
            // the shared on-disk cache, but a hard quit doesn't. If a different
            // account just signed in on this device, clear the prior user's
            // cached mail before the new session populates it.
            if !lastUsername.isEmpty, lastUsername != username {
                await newClient.clearLocalData()
            }
            self.controlDomain = controlDomain
            self.lastUsername = username
            self.client = newClient
            self.status = .signedIn
            startInboxBadgePolling()
            requestContactsAccessIfNeeded()
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
        // Wipe locally cached mail (envelopes, bodies, drafts, outbox) before
        // dropping the session so the next account to sign in on this device
        // can't read the previous user's messages from the shared on-disk
        // cache.
        await client.clearLocalData()
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
            requestContactsAccessIfNeeded()
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
            inboxUnreadCount = max(0, status.unseen ?? 0)
            try? await UNUserNotificationCenter.current().setBadgeCount(inboxUnreadCount)
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
        default:                  return nil
        }
    }
}

// MARK: - Cache directory

extension AppState {
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
    }

    /// Replace the whole unread map. Used by the folder list view model
    /// after a full STATUS walk so any folders that have disappeared
    /// drop out.
    func setUnreadCounts(_ counts: [String: Int]) {
        folderUnreadCounts = counts.mapValues { max(0, $0) }
    }

    /// Bump (or reduce) the count for one folder. Clamped at zero so a
    /// stale +1 from a doubled signal can't make the badge negative.
    func applyUnreadDelta(folderPath: String, delta: Int) {
        let current = folderUnreadCounts[folderPath] ?? 0
        folderUnreadCounts[folderPath] = max(0, current + delta)
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
    /// the request. Used by the mailto: URL handler; menu shortcuts
    /// and toolbar buttons continue to call the zero-arg form, which
    /// leaves `pendingComposeSeed` nil and lets the receiver fall
    /// back to a fresh draft.
    func requestCompose(seed: Draft) {
        pendingComposeSeed = seed
        composeRequestTick += 1
    }

    /// Reads and clears the pending compose seed. Called by the
    /// compose-request receiver in `MessageListView` both on
    /// `.onChange(of: composeRequestTick)` (warm path) and on the
    /// view's initial `.task` (cold-launch mailto: arrived before the
    /// view was in the hierarchy).
    func consumePendingComposeSeed() -> Draft? {
        defer { pendingComposeSeed = nil }
        return pendingComposeSeed
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
