import Foundation
import CabalmailKit

/// Which folders' counts one write moves, decided when the write starts, and
/// the moves themselves, so a write and its revert always move the same
/// folders (`MailMutationService`).
///
/// Unread counts move in the folders the store has a count for, and in
/// INBOX, whose count is also the app badge; flagged counts move in the
/// folders that have a flagged count. A folder with none (not opened or
/// counted this session) is left alone, and so is the revert: a delta there
/// would invent a count from 0, and taking it back would save that guess
/// over the folder's real saved count.
@MainActor
struct CountMoves {
    private let counts: MailCounts
    private let unreadFolders: Set<String>
    private let flaggedFolders: Set<String>

    init(counts: MailCounts, folders: some Sequence<String>) {
        let folders = Set(folders)
        self.counts = counts
        unreadFolders = folders.filter { counts.folderUnreadCounts[$0] != nil || MailCounts.isInbox($0) }
        flaggedFolders = folders.filter { counts.folderFlaggedCounts[$0] != nil }
    }

    /// Whether this write moves `folder`'s unread count.
    func movesUnread(in folder: String) -> Bool {
        unreadFolders.contains(folder)
    }

    /// Moves each folder's unread count by `delta` per message of `refs`.
    func moveUnread(_ refs: some Sequence<MessageRef>, by delta: Int) {
        for (folder, uids) in refs.uidsByFolder() where unreadFolders.contains(folder) {
            counts.applyUnreadDelta(folderPath: folder, delta: delta * uids.count)
        }
    }

    /// Moves `destination`'s unread count by `delta` per message of `refs`:
    /// unread messages a plain move carries in (1), or takes back out (-1).
    func moveUnread(_ refs: some Collection<MessageRef>, into destination: String, by delta: Int) {
        guard unreadFolders.contains(destination), !refs.isEmpty else { return }
        counts.applyUnreadDelta(folderPath: destination, delta: delta * refs.count)
    }

    /// Moves each folder's flagged count by `delta` per message of `refs`.
    func moveFlagged(_ refs: some Sequence<MessageRef>, by delta: Int) {
        for (folder, uids) in refs.uidsByFolder() where flaggedFolders.contains(folder) {
            counts.applyFlaggedDelta(folderPath: folder, delta: delta * uids.count)
        }
    }

    /// Moves the count `flag` stands for, if any, for `refs` whose flag was
    /// `added` (or removed): a `\Seen` added lowers the unread count, a
    /// `\Flagged` added raises the flagged count.
    func move(_ flag: Flag, added: Bool, for refs: some Sequence<MessageRef>) {
        switch flag {
        case .seen: moveUnread(refs, by: added ? -1 : 1)
        case .flagged: moveFlagged(refs, by: added ? 1 : -1)
        default: break
        }
    }
}
