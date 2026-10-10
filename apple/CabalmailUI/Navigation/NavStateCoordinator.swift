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
///   the same place. Persisted through `ResumeSessionStore`. With several
///   windows, only the one the user last used moves it (`WindowRecorder`);
///   each window also keeps its own route (`StoredRoute`).
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
public final class NavStateCoordinator {
    /// True once the launch-time cursor fetch has run. `MailRootView` uses it
    /// to tell the cold-launch path from a later foreground (both may offer
    /// the cross-device toast, through different entry points).
    var hasLoadedInitial = false

    public let clientID: String
    let client: CabalmailClient

    // Working server cursor — what a save would persist.
    var folder: String?
    var messageID: String?
    var uid: UInt32?
    var uidValidity: UInt32?
    var listScroll: Int?
    var messageScroll: Int?
    var messageAnchor: String?
    var messageFraction: Double?
    /// Which kind of cursor a save writes: the mail fields above, or the feed
    /// item below (resume-session plan, Phase C).
    var activeKind: NavState.Kind = .mail
    var feedCursorItem: String?
    var feedCursorScope: String?
    var feedAnchor: String?
    var feedFraction: Double?
    /// Server writes are held from launch until the cross-device probe has
    /// read the cursor another install left; the latest snapshot is written
    /// on release. Otherwise this launch's own landing could overwrite the
    /// very cursor the probe is about to look for.
    var serverWritesHeld = true
    var heldSnapshot: NavState?

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
    /// Set once any landing has read `launchSession`. After that, a root
    /// view rebuilt mid-process (a compact/regular size-class flip, #1555)
    /// lands on the *live* `session` — where the user is now — rather than
    /// re-landing on where the process started.
    var didConsumeLaunchSession = false
    /// The list place the last run left (`ResumeSession.listAnchor`), for
    /// the process's first mail landing to take (`mailLaunchTarget`).
    var launchListAnchor: ListAnchor?
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
        self.launchListAnchor = loaded?.listAnchor
        self.session = loaded ?? ResumeSession(section: .mail)
        self.positions = store.loadPositions()
        self.lastSeenUpdatedAt = store.offeredForeignUpdatedAt
    }

    // MARK: Restore application

    /// A restore or jump to `cursor` is starting in some window: primes every
    /// working-cursor field from it, so a save before the list selects the
    /// message writes where the user is going. The window parks the restore
    /// itself (`WindowRestores`).
    func primeCursor(for cursor: NavState) {
        folder = cursor.folder
        messageID = cursor.messageID
        uid = cursor.uid
        uidValidity = cursor.uidValidity
        listScroll = cursor.listScroll
        messageScroll = cursor.messageScroll
        messageAnchor = cursor.messageAnchor
        messageFraction = cursor.messageFraction
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
        messageFraction = nil
        activeKind = .mail
        session.section = .mail
        // The list's place is its folder's: the same folder recorded again
        // (the launch landing) keeps it.
        if session.folder != folderPath { session.listAnchor = nil }
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
    /// This install only echoes a UIDVALIDITY it was handed, and only beside
    /// the message it came with: a restore's stays while the cursor still
    /// names the restored message (its list selecting it records it again),
    /// and any other message clears it (#1873).
    func recordMessage(folderPath: String, uid: UInt32, messageID: String?) {
        if folder != folderPath || self.uid != uid { uidValidity = nil }
        folder = folderPath
        self.uid = uid
        self.messageID = messageID
        messageScroll = nil
        messageAnchor = nil
        messageFraction = nil
        activeKind = .mail
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
        messageFraction = atTop ? nil : position.fraction
        scheduleSave()
        savePosition(
            key: ReadingPositionKey.mail(messageID: messageID, folder: folderPath, uid: uid),
            anchor: position.anchor,
            offset: position.offset,
            fraction: position.fraction,
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
        messageFraction = nil
        session.clearMessage()
        scheduleSessionSave()
        scheduleSave()
    }

    /// The cursor a save would write now: the feed item when the user is
    /// reading one, else the mail position.
    var workingCursor: NavState? {
        if activeKind == .rss, let feedCursorItem {
            return .feed(itemID: feedCursorItem, scope: feedCursorScope, anchor: feedAnchor,
                         fraction: feedFraction, clientID: clientID)
        }
        guard let folder else { return nil }
        return NavState(
            folder: folder,
            messageID: messageID,
            uid: uid,
            uidValidity: uidValidity,
            listScroll: listScroll,
            messageScroll: messageScroll,
            messageAnchor: messageAnchor,
            messageFraction: messageFraction,
            clientID: clientID
        )
    }

    func scheduleSave() {
        guard let snapshot = workingCursor else { return }
        saveTask?.cancel()
        let debounce = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            if self.serverWritesHeld {
                self.heldSnapshot = snapshot
                return
            }
            await self.persist(snapshot)
        }
    }

    /// The launch probe has run: stop holding server writes and write the
    /// newest position recorded meanwhile.
    func releaseServerWrites() {
        guard serverWritesHeld else { return }
        serverWritesHeld = false
        guard let held = heldSnapshot else { return }
        heldSnapshot = nil
        Task { [weak self] in await self?.persist(held) }
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

// MARK: - MessageRef entry points

// The reader and the shells name the open message by its `MessageRef`; the
// cursor and the resume record keep their own (folder, uid, Message-ID)
// fields, so these forward to the field-wise forms. The ref's UIDVALIDITY is
// never written into the cursor: it carries the one a restore primed it
// with while it still names that message, or none.
extension NavStateCoordinator {
    /// A restore of the message `ref` names: a window re-parking its open
    /// message for the list a layout swap rebuilt (`SceneNavigator`). Carries
    /// the ref's UIDVALIDITY when it has one.
    func restoreCursor(for ref: MessageRef) -> NavState {
        NavState(
            folder: ref.folder, messageID: ref.messageId, uid: ref.uid, uidValidity: ref.uidValidity,
            clientID: clientID
        )
    }

    /// Records that the user opened the message `ref` names.
    func recordMessage(_ ref: MessageRef) {
        recordMessage(folderPath: ref.folder, uid: ref.uid, messageID: ref.messageId)
    }

    /// `recordMessageScroll(folderPath:uid:messageID:position:atTop:)` for
    /// the message `ref` names.
    func recordMessageScroll(_ ref: MessageRef, position: ReadingPosition, atTop: Bool) {
        recordMessageScroll(
            folderPath: ref.folder, uid: ref.uid, messageID: ref.messageId,
            position: position, atTop: atTop
        )
    }

    /// The reading position of the message `ref` names, without the cursor:
    /// a reader in a window that does not record (`WindowRecorder`) still
    /// keeps where the user was in the message.
    func savePosition(for ref: MessageRef, position: ReadingPosition, atTop: Bool) {
        savePosition(
            key: ReadingPositionKey.mail(ref), anchor: position.anchor, offset: position.offset,
            fraction: position.fraction, atTop: atTop
        )
    }
}
