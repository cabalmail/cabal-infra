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
/// - **Launch** (`initialCursor`): fetch once, restore silently. No prompt —
///   the user opened this client to use it.
/// - **Foreground** (`foreignCursorOnForeground`): fetch again; if the cursor
///   now carries a different `clientID` and a newer `updatedAt` than we last
///   saw, surface it for the "pick up where you left off" toast. Our own
///   writes never trip this (same `clientID`).
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

    private var saveTask: Task<Void, Never>?
    /// The last body actually written, to skip redundant network writes.
    private var lastSavedBody: NSDictionary?
    /// Newest `updatedAt` we've already accounted for, so a foreign cursor the
    /// user dismissed isn't re-offered on every foreground.
    private var lastSeenUpdatedAt: Int64 = 0
    private var restoreTick = 0
    /// Debounce window for cursor saves. Long enough that a quick folder→
    /// message→scroll sequence collapses to one write.
    private let saveDebounce: Duration = .seconds(1)

    init(client: CabalmailClient, clientID: String = InstallIdentity.clientID()) {
        self.client = client
        self.clientID = clientID
    }

    // MARK: Launch restore

    /// Fetches the saved cursor once. Returns it so `MailRootView` can select
    /// the folder; subsequent calls return nil. Records the cursor's recency so
    /// the same position isn't later offered back as a cross-client jump.
    func initialCursor() async -> NavState? {
        guard !hasLoadedInitial else { return nil }
        hasLoadedInitial = true
        guard let cursor = try? await client.navState() else { return nil }
        lastSeenUpdatedAt = max(lastSeenUpdatedAt, cursor.updatedAt ?? 0)
        return cursor
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
        restoreTick += 1
        pendingRestore = PendingRestore(
            folderPath: cursor.folder,
            messageID: cursor.messageID,
            uid: cursor.uid,
            listScroll: cursor.listScroll,
            tick: restoreTick
        )
    }

    /// Returns and clears the pending restore for `folderPath`, if it targets
    /// that folder. The list calls this after its initial load.
    func consumePendingRestore(for folderPath: String) -> PendingRestore? {
        guard let restore = pendingRestore, restore.folderPath == folderPath else { return nil }
        pendingRestore = nil
        return restore
    }

    // MARK: Recording

    /// Records that the user is now in `folderPath` (no message yet). Folder is
    /// the highest-priority cursor field, so this always schedules a save.
    func recordFolder(_ folderPath: String) {
        folder = folderPath
        messageID = nil
        uid = nil
        uidValidity = nil
        listScroll = nil
        scheduleSave()
    }

    /// Records that the user opened a message in `folderPath`.
    func recordMessage(folderPath: String, uid: UInt32, messageID: String?) {
        folder = folderPath
        self.uid = uid
        self.messageID = messageID
        scheduleSave()
    }

    /// Records that the message selection in `folderPath` cleared (back to the
    /// list). No-op if the working cursor isn't on that folder or already has
    /// no message.
    func recordNoMessage(folderPath: String) {
        guard folder == folderPath, uid != nil || messageID != nil else { return }
        uid = nil
        messageID = nil
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
