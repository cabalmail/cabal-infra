import Foundation
import Observation
import CabalmailKit

/// Owns "where the user is" for one signed-in session, in two layers
/// (`docs/1.x/resume-session-plan.md`):
///
/// - **The local resume session** (`ResumeSession`, per install, never leaves
///   the device): the section (mail or feeds), list scope, open item, and —
///   in `ReadingPositionCache` — where the reader was in each item's body. A
///   cold launch restores it silently; reopening a half-read item lands at
///   the same place. Persisted through `ResumeSessionStore`.
/// - **The server cursor** (`NavState`, `/set_nav_state`): the cross-device
///   signal. Recorded debounced as the user moves through mail; read on
///   launch and foreground, and offered as a "pick up where you left off"
///   toast *only* when written by another install and newer than anything
///   this install has already been shown. A device is never offered its own
///   position — the local layer has already restored it.
///
/// Created by `AppState` when a client is wired (sign-in or restore) and torn
/// down on sign-out. `@MainActor` because it's driven entirely from SwiftUI
/// `.onChange` handlers and read by views. The session-layer surface lives in
/// `NavStateCoordinator+Session.swift`.
@Observable
@MainActor
final class NavStateCoordinator {
    /// A restore target handed to the `MessageListView` for a folder: it finds
    /// the matching envelope after its initial load and selects it. Carried as
    /// a value (not applied here) because only the list owns the loaded
    /// envelopes and the wide/compact selection machinery.
    struct PendingRestore: Equatable, Sendable {
        let folderPath: String
        let messageID: String?
        let uid: UInt32?
        let listScroll: Int?
        /// Monotonic so an already-mounted list re-applies even when the same
        /// folder/message recurs (e.g. a same-folder cross-device jump).
        let tick: Int
    }

    /// Set when a folder's message should be restored or jumped to; consumed by
    /// the matching `MessageListView`.
    private(set) var pendingRestore: PendingRestore?

    /// An in-message scroll position to reapply once the reader opens the
    /// restored message. Consumed by `MessageDetailView` (which owns the body
    /// renderer), keyed by folder + message so it only lands on the intended
    /// message. `offset` restores a plain-text body; `anchor` restores an HTML
    /// body — a message renders as one or the other, so the reader applies
    /// whichever matches.
    struct PendingScrollRestore: Equatable, Sendable {
        let folderPath: String
        let messageID: String?
        let uid: UInt32?
        let offset: Int?
        let anchor: String?
    }

    /// Set alongside `pendingRestore` when the restored cursor carried a scroll
    /// position; consumed by the reader after the message loads.
    private(set) var pendingScrollRestore: PendingScrollRestore?

    /// A feed item to select once its scope is on screen (the launch restore
    /// of the feed reader). Consumed by the feed navigation's
    /// `onChange(of: selectedScope)` — see `consumeFeedItemRestore`.
    struct PendingFeedRestore: Equatable, Sendable {
        let scope: RssItemScope
        let item: RssItem
    }

    var pendingFeedRestore: PendingFeedRestore?

    /// Set by the resume toast's action; observed by `MailRootView`, which
    /// selects the folder and schedules the message restore, then clears it.
    var navigateRequest: NavState?

    /// True once the launch-time cursor fetch has run. `MailRootView` uses it
    /// to tell the cold-launch path from a later foreground (both may offer
    /// the cross-device toast, through different entry points).
    var hasLoadedInitial = false

    let clientID: String
    let client: CabalmailClient

    // Working server cursor — what a save would persist.
    var folder: String?
    var messageID: String?
    var uid: UInt32?
    var uidValidity: UInt32?
    var listScroll: Int?
    var messageScroll: Int?
    var messageAnchor: String?

    // Local resume layer (see the `+Session` extension).
    let store: ResumeSessionStore
    /// The session as it was when this coordinator was created — the record
    /// every launch-restore path reads. Frozen here because `session` starts
    /// changing the moment the landing records itself.
    let launchSession: ResumeSession?
    /// The live session record; mutated by every recording call.
    var session: ResumeSession
    var positions: ReadingPositionCache
    var sessionSaveTask: Task<Void, Never>?
    var positionsDirty = false
    /// One-shot guard for the feed reader's launch restore
    /// (`consumeFeedsLaunchTarget`), so the Feeds tab re-appearing later in
    /// the process doesn't yank its selection back.
    var didConsumeFeedsLaunch = false
    /// Debounce for local session writes — short, since it's a local
    /// `UserDefaults` write, and `flushSession` covers the scene going away.
    let sessionSaveDebounce: Duration = .milliseconds(300)

    private var saveTask: Task<Void, Never>?
    /// The last body actually written, to skip redundant network writes.
    private var lastSavedBody: NSDictionary?
    /// Newest foreign `updatedAt` already offered to the user, so an ignored
    /// cross-device toast isn't re-offered on every foreground — or, since it
    /// is persisted, on the next launch.
    var lastSeenUpdatedAt: Int64 {
        didSet { store.offeredForeignUpdatedAt = lastSeenUpdatedAt }
    }
    private var restoreTick = 0
    /// Set by `armProvisionalLanding`: swallow the next `recordFolder`'s server
    /// write (the launch landing) so the cursor probe reads what another
    /// client left, not what this launch just wrote. Released by
    /// `materializeLanding` once the probe has run.
    private var suppressNextFolderRecord = false
    /// Debounce window for cursor saves. Long enough that a quick folder→
    /// message→scroll sequence collapses to one write.
    private let saveDebounce: Duration = .seconds(1)

    init(
        client: CabalmailClient,
        clientID: String = InstallIdentity.clientID(),
        store: ResumeSessionStore = ResumeSessionStore()
    ) {
        self.client = client
        self.clientID = clientID
        self.store = store
        let loaded = store.loadSession()
        self.launchSession = loaded
        self.session = loaded ?? ResumeSession(section: .mail)
        self.positions = store.loadPositions()
        self.lastSeenUpdatedAt = store.offeredForeignUpdatedAt
    }

    // MARK: Restore application

    /// Schedules a restore/jump to `cursor`: primes the working cursor and
    /// publishes a `PendingRestore` for the matching list to consume.
    func scheduleRestore(for cursor: NavState) {
        folder = cursor.folder
        messageID = cursor.messageID
        uid = cursor.uid
        uidValidity = cursor.uidValidity
        listScroll = cursor.listScroll
        messageScroll = cursor.messageScroll
        messageAnchor = cursor.messageAnchor
        restoreTick += 1
        pendingRestore = PendingRestore(
            folderPath: cursor.folder,
            messageID: cursor.messageID,
            uid: cursor.uid,
            listScroll: cursor.listScroll,
            tick: restoreTick
        )
        // Only publish a scroll restore when the cursor actually carried one, so
        // the reader doesn't force a message that was saved at the top back to
        // the top redundantly.
        if cursor.messageScroll != nil || cursor.messageAnchor != nil {
            pendingScrollRestore = PendingScrollRestore(
                folderPath: cursor.folder,
                messageID: cursor.messageID,
                uid: cursor.uid,
                offset: cursor.messageScroll,
                anchor: cursor.messageAnchor
            )
        } else {
            pendingScrollRestore = nil
        }
    }

    /// Drops a scheduled message restore whose folder turned out not to exist
    /// (the launch landing fell back to INBOX).
    func clearPendingRestore() {
        pendingRestore = nil
        pendingScrollRestore = nil
    }

    /// Returns and clears the pending restore for `folderPath`, if it targets
    /// that folder. The list calls this after its initial load.
    func consumePendingRestore(for folderPath: String) -> PendingRestore? {
        guard let restore = pendingRestore, restore.folderPath == folderPath else { return nil }
        pendingRestore = nil
        return restore
    }

    /// Returns and clears the pending scroll restore if it targets the message
    /// `MessageDetailView` just opened — matched by folder plus Message-ID
    /// (durable across a move) or UID. The reader calls this once the body has
    /// loaded and applies `offset` (plain text) or `anchor` (HTML).
    func consumeScrollRestore(folderPath: String, uid: UInt32?, messageID: String?) -> PendingScrollRestore? {
        guard let restore = pendingScrollRestore, restore.folderPath == folderPath else { return nil }
        let messageMatches: Bool
        if let wanted = restore.messageID, let have = messageID {
            messageMatches = wanted == have
        } else if let wanted = restore.uid, let have = uid {
            messageMatches = wanted == have
        } else {
            messageMatches = false
        }
        guard messageMatches else { return nil }
        pendingScrollRestore = nil
        return restore
    }

    // MARK: Recording (mail)

    /// Arms suppression of the next folder record's server write. The launch
    /// landing calls this before selecting its folder, so the cursor probe
    /// that follows reads another client's cursor rather than this launch's
    /// own landing. Released by `materializeLanding` (or consumed by the next
    /// `recordFolder`, which still updates the working cursor and the local
    /// session).
    func armProvisionalLanding() {
        suppressNextFolderRecord = true
    }

    /// The launch probe has run: persist whatever the working cursor holds
    /// now. Deliberately not a `recordFolder` — by the time the probe returns
    /// the list may already have restored a message, and re-recording the bare
    /// folder would wipe it.
    func materializeLanding() {
        suppressNextFolderRecord = false
        scheduleSave()
    }

    /// Records that the user is now in `folderPath` (no message yet). Folder is
    /// the highest-priority cursor field, so this normally schedules a save —
    /// except for the launch landing, whose server write is held back until
    /// the probe has run (`armProvisionalLanding`).
    func recordFolder(_ folderPath: String) {
        folder = folderPath
        messageID = nil
        uid = nil
        uidValidity = nil
        listScroll = nil
        messageScroll = nil
        messageAnchor = nil
        session.section = .mail
        session.folder = folderPath
        session.clearMessage()
        scheduleSessionSave()
        if suppressNextFolderRecord {
            suppressNextFolderRecord = false
            return
        }
        scheduleSave()
    }

    /// Records that the user opened a message in `folderPath`. A freshly-opened
    /// message starts at the top as far as the *server* cursor knows — the
    /// reader consults the local position cache for where it really was.
    func recordMessage(folderPath: String, uid: UInt32, messageID: String?) {
        folder = folderPath
        self.uid = uid
        self.messageID = messageID
        messageScroll = nil
        messageAnchor = nil
        session.section = .mail
        session.folder = folderPath
        session.uid = uid
        session.messageID = messageID
        scheduleSessionSave()
        scheduleSave()
    }

    /// Records the current in-message scroll position for the open message —
    /// an exact `offset` for a plain-text body, a structural `anchor` for an
    /// HTML body (`position` carries one or the other) — on the server cursor
    /// and in the local position cache. A position at the top (`atTop`)
    /// clears both rather than storing a trivial value. Ignored unless the
    /// working cursor is still on that message, so a late capture from a
    /// message the user already left can't mis-attach.
    func recordMessageScroll(
        folderPath: String,
        uid: UInt32,
        messageID: String?,
        position: ReadingPosition,
        atTop: Bool
    ) {
        guard folder == folderPath, self.uid == uid else { return }
        messageScroll = atTop ? nil : position.offset
        messageAnchor = atTop ? nil : position.anchor
        scheduleSave()
        savePosition(
            key: ReadingPositionKey.mail(messageID: messageID, folder: folderPath, uid: uid),
            anchor: position.anchor,
            offset: position.offset,
            atTop: atTop
        )
    }

    /// Records that the message selection in `folderPath` cleared (back to the
    /// list). No-op if the working cursor isn't on that folder or already has
    /// no message.
    func recordNoMessage(folderPath: String) {
        guard folder == folderPath, uid != nil || messageID != nil else { return }
        uid = nil
        messageID = nil
        messageScroll = nil
        messageAnchor = nil
        session.clearMessage()
        scheduleSessionSave()
        scheduleSave()
    }

    private func scheduleSave() {
        guard let folder else { return }
        let snapshot = NavState(
            folder: folder,
            messageID: messageID,
            uid: uid,
            uidValidity: uidValidity,
            listScroll: listScroll,
            messageScroll: messageScroll,
            messageAnchor: messageAnchor,
            clientID: clientID
        )
        saveTask?.cancel()
        let debounce = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.persist(snapshot)
        }
    }

    private func persist(_ cursor: NavState) async {
        let body = NSDictionary(dictionary: cursor.requestBody)
        if let lastSavedBody, lastSavedBody.isEqual(to: cursor.requestBody) { return }
        do {
            try await client.setNavState(cursor)
            lastSavedBody = body
        } catch {
            // Best-effort: a failed cursor write is never worth surfacing.
            // The next change reschedules, and launch/foreground reconcile
            // recovers the position from whatever did persist.
        }
    }
}
