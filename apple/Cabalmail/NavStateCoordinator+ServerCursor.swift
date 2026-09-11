import Foundation
import CabalmailKit

// The server-cursor half of `NavStateCoordinator`: the launch and foreground
// probes that decide whether another install's `NavState` is worth offering
// as the "pick up where you left off" toast. Reads only; the writes live with
// the recording calls in the main file.
extension NavStateCoordinator {
    // MARK: Launch

    /// Envelopes the message list loads on first open
    /// (`MessageListViewModel.pageSize`). Launch reachability is checked against
    /// this same window, so a cursor we vouch for always resolves to a
    /// selectable row when the user taps Resume.
    static let initialWindow: UInt32 = 50

    /// Fetches the server cursor once and returns it *only* if it is a
    /// cross-device resume target worth offering: written by another install,
    /// newer than anything already offered here, its folder still exists and,
    /// when a message was recorded, that message is still in the folder's
    /// initial window. Returns nil otherwise so the launch landing stands with
    /// no prompt. Never restores — the caller offers a toast. Marks the cursor
    /// as offered so neither the foreground path nor the next launch repeats
    /// it.
    func launchResumeCandidate(folders: [Folder]) async -> NavState? {
        guard !hasLoadedInitial else { return nil }
        hasLoadedInitial = true
        guard let cursor = try? await client.navState() else { return nil }
        // This install's own cursor is never offered back to it: the local
        // session has already put the user there.
        guard cursor.isForeign(to: clientID),
              let updatedAt = cursor.updatedAt, updatedAt > lastSeenUpdatedAt
        else { return nil }
        // Another install parked on the very place the local session just
        // restored: nothing to offer, and nothing to offer again later.
        if Self.cursor(cursor, matches: launchSession) {
            lastSeenUpdatedAt = updatedAt
            return nil
        }
        // The folder must still exist (another client may have deleted it).
        guard folders.contains(where: { $0.path == cursor.folder }) else { return nil }
        // A message cursor must still be reachable in that folder.
        if cursor.messageID != nil || cursor.uid != nil {
            let reachable = await messageIsReachable(cursor)
            if !reachable { return nil }
        }
        lastSeenUpdatedAt = updatedAt
        return cursor
    }

    /// Whether `cursor`'s recorded message is present in its folder's initial
    /// window — the same page (`status` + `topEnvelopes`) the list loads on
    /// open — matched by Message-ID first then UID, exactly as the list's
    /// restore does. Any probe failure returns false: we never offer a resume
    /// we can't stand behind.
    func messageIsReachable(_ cursor: NavState) async -> Bool {
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
        // The other install is where this one already is: no prompt.
        if Self.cursor(cursor, matchesFolder: folder, uid: uid, messageID: messageID) { return nil }
        return cursor
    }

    // MARK: Same-place checks

    /// Whether `cursor` names the position `session` would restore: same
    /// folder and — when either side names a message — the same message, by
    /// Message-ID when both carry one, else by UID.
    static func cursor(_ cursor: NavState, matches session: ResumeSession?) -> Bool {
        guard let session, session.section == .mail else { return false }
        return Self.cursor(cursor, matchesFolder: session.folder, uid: session.uid, messageID: session.messageID)
    }

    static func cursor(_ cursor: NavState, matchesFolder folder: String?, uid: UInt32?, messageID: String?) -> Bool {
        guard let folder, cursor.folder == folder else { return false }
        let cursorHasMessage = cursor.uid != nil || cursor.messageID != nil
        let localHasMessage = uid != nil || messageID != nil
        guard cursorHasMessage || localHasMessage else { return true }
        guard cursorHasMessage, localHasMessage else { return false }
        if let wanted = cursor.messageID, let have = messageID {
            return wanted == have
        }
        return cursor.uid != nil && cursor.uid == uid
    }
}
