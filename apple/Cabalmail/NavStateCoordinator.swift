import Foundation
import Observation
import CabalmailKit

/// Owns the cross-client navigation cursor for one signed-in session: it
/// records where the user is (debounced, server-side), restores that position
/// on launch, and — on foreground — detects a cursor written by *another*
/// client so the UI can offer to follow it.
///
/// Created by `AppState` when a client is wired (sign-in or restore) and torn
/// down on sign-out. `@MainActor` because it's driven entirely from SwiftUI
/// `.onChange` handlers and read by views.
///
/// Cursor lifecycle:
/// - **Launch** (`launchResumeCandidate`): fetch once and land on INBOX
///   regardless — never restore silently. If the saved folder still exists and
///   the recorded message is still in that folder's initial window, return the
///   cursor so `MailRootView` can offer a "pick up where you left off" toast.
///   Until the user taps it they stay in INBOX, and the default landing is held
///   back from overwriting the saved cursor (`armProvisionalLanding`).
/// - **Foreground** (`foreignCursorOnForeground`): fetch again; if the cursor
///   now carries a different `clientID` and a newer `updatedAt` than we last
///   saw, surface it for the same toast. Our own writes never trip this (same
///   `clientID`).
/// - **Recording** (`recordFolder`/`recordMessage`): update the working cursor
///   and debounce a save, so only the active client writes, and only on change.
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

    /// Set by the resume toast's action; observed by `MailRootView`, which
    /// selects the folder and schedules the message restore, then clears it.
    var navigateRequest: NavState?

    /// True once the launch-time cursor fetch has run. `MailRootView` uses it
    /// to tell a cold launch (silent restore) from a later foreground (offer
    /// the cross-client jump).
    private(set) var hasLoadedInitial = false

    let clientID: String
    private let client: CabalmailClient

    // Working cursor — what a save would persist.
    private var folder: String?
    private var messageID: String?
    private var uid: UInt32?
    private var uidValidity: UInt32?
    private var listScroll: Int?
    private var messageScroll: Int?
    private var messageAnchor: String?

    private var saveTask: Task<Void, Never>?
    /// The last body actually written, to skip redundant network writes.
    private var lastSavedBody: NSDictionary?
    /// Newest `updatedAt` we've already accounted for, so a foreign cursor the
    /// user dismissed isn't re-offered on every foreground.
    private var lastSeenUpdatedAt: Int64 = 0
    private var restoreTick = 0
    /// Set by `armProvisionalLanding`: swallow the next `recordFolder` (the
    /// launch INBOX landing) without persisting, so a still-valid saved cursor
    /// isn't overwritten before the user acts on the resume toast.
    private var suppressNextFolderRecord = false
    /// Debounce window for cursor saves. Long enough that a quick folder→
    /// message→scroll sequence collapses to one write.
    private let saveDebounce: Duration = .seconds(1)

    init(client: CabalmailClient, clientID: String = InstallIdentity.clientID()) {
        self.client = client
        self.clientID = clientID
    }

    // MARK: Launch restore

    /// Envelopes the message list loads on first open
    /// (`MessageListViewModel.pageSize`). Launch reachability is checked against
    /// this same window, so a cursor we vouch for always resolves to a
    /// selectable row when the user taps Resume.
    private static let initialWindow: UInt32 = 50

    /// Fetches the saved cursor once and returns it *only* if it's still a
    /// usable resume target: the folder still exists and, when a message was
    /// recorded, that message is still in the folder's initial window. Returns
    /// nil otherwise (no cursor, folder deleted, message moved/expunged) so
    /// `MailRootView` simply stays in INBOX with no prompt. Never restores — the
    /// caller offers a toast. Records the cursor's recency so the same position
    /// isn't later re-offered by the foreground cross-client path.
    func launchResumeCandidate(folders: [Folder]) async -> NavState? {
        guard !hasLoadedInitial else { return nil }
        hasLoadedInitial = true
        guard let cursor = try? await client.navState() else { return nil }
        lastSeenUpdatedAt = max(lastSeenUpdatedAt, cursor.updatedAt ?? 0)
        // The folder must still exist (another client may have deleted it).
        guard folders.contains(where: { $0.path == cursor.folder }) else { return nil }
        // A folder-only cursor has no message to verify; a message cursor must
        // still be reachable in that folder.
        if cursor.messageID != nil || cursor.uid != nil {
            let reachable = await messageIsReachable(cursor)
            if !reachable { return nil }
        }
        return cursor
    }

    /// Whether `cursor`'s recorded message is present in its folder's initial
    /// window — the same page (`status` + `topEnvelopes`) the list loads on
    /// open — matched by Message-ID first then UID, exactly as the list's
    /// restore does. Any probe failure returns false: we never offer a resume
    /// we can't stand behind.
    private func messageIsReachable(_ cursor: NavState) async -> Bool {
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: cursor.folder)
            let total = UInt32(max(0, status.messages ?? 0))
            guard total > 0 else { return false }
            let window = try await client.imapClient.topEnvelopes(
                folder: cursor.folder,
                limit: Self.initialWindow,
                totalMessages: total
            )
            if let messageID = cursor.messageID,
               window.contains(where: { $0.messageId == messageID }) {
                return true
            }
            if let uid = cursor.uid, window.contains(where: { $0.uid == uid }) {
                return true
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: Foreground reconcile

    /// On foreground, returns a cursor written by another client that is newer
    /// than anything we've seen — the candidate for the resume toast — or nil.
    func foreignCursorOnForeground() async -> NavState? {
        guard let cursor = try? await client.navState(),
              cursor.isForeign(to: clientID),
              let updatedAt = cursor.updatedAt,
              updatedAt > lastSeenUpdatedAt
        else { return nil }
        lastSeenUpdatedAt = updatedAt
        return cursor
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

    // MARK: Recording

    /// Arms suppression of the next folder record. `MailRootView` calls this
    /// before it default-selects INBOX at launch while a resume may be pending,
    /// so that landing doesn't clobber the saved cursor. Cleared by the first
    /// `recordFolder` (the landing), or explicitly recorded once the probe
    /// confirms there's nothing to resume.
    func armProvisionalLanding() {
        suppressNextFolderRecord = true
    }

    /// Records that the user is now in `folderPath` (no message yet). Folder is
    /// the highest-priority cursor field, so this normally schedules a save —
    /// except for the launch INBOX landing, which updates the working cursor
    /// but must not persist over a still-valid saved position.
    func recordFolder(_ folderPath: String) {
        folder = folderPath
        messageID = nil
        uid = nil
        uidValidity = nil
        listScroll = nil
        messageScroll = nil
        messageAnchor = nil
        if suppressNextFolderRecord {
            suppressNextFolderRecord = false
            return
        }
        scheduleSave()
    }

    /// Records that the user opened a message in `folderPath`. A freshly-opened
    /// message starts at the top, so any prior in-message scroll is cleared —
    /// `recordMessageScroll` re-populates it as the user reads.
    func recordMessage(folderPath: String, uid: UInt32, messageID: String?) {
        folder = folderPath
        self.uid = uid
        self.messageID = messageID
        messageScroll = nil
        messageAnchor = nil
        scheduleSave()
    }

    /// Records the current in-message scroll position for the open message —
    /// an exact `offset` for a plain-text body, a structural `anchor` for an
    /// HTML body. Ignored unless the working cursor is still on that message,
    /// so a late capture from a message the user already left can't mis-attach.
    func recordMessageScroll(folderPath: String, uid: UInt32, offset: Int?, anchor: String?) {
        guard folder == folderPath, self.uid == uid else { return }
        messageScroll = offset
        messageAnchor = anchor
        scheduleSave()
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
