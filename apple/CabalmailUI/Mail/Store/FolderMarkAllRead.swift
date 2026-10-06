import Foundation
import CabalmailKit

/// Marks every unseen message in a mail folder read in one server call
/// (`/mark_folder_read`, cross-media plan decision 6), then brings the
/// client's own state into line.
///
/// One routine for the three surfaces that offer it — the sidebar folder's
/// context menu (`FolderListViewModel`), the message list's overflow menu and
/// the Mailbox menu (`MessageListViewModel`) — so the after-effects can never
/// drift: the folder's envelope-cache snapshot is marked read to match, the
/// sidebar badge zeroes its unread while keeping the total, and the visible
/// list hard-reloads so the rows re-render read. The snapshot is rewritten
/// rather than dropped: dropped, a folder not on screen had no saved list
/// until it was next opened online, so offline it showed no messages (#1850).
/// Modelled on `FolderListViewModel.emptyTrash()`.
@MainActor
enum FolderMarkAllRead {
    /// Returns how many messages the server flipped. Throws the transport or
    /// Lambda error for the caller to surface in its own `errorMessage`.
    @discardableResult
    static func perform(folderPath: String, client: CabalmailClient, mailStore: MailSessionStore) async throws -> Int {
        let flipped = try await client.imapClient.markFolderRead(folder: folderPath)
        try? await client.envelopeCache.markAllSeen(folder: folderPath)
        // Signed out meanwhile: the badge is the last account's (#1848).
        guard mailStore.acceptsCounts(from: client) else { return flipped }
        if let total = mailStore.counts.folderTotalCounts[folderPath] {
            mailStore.counts.setFolderCounts(folderPath: folderPath, unread: 0, total: total)
        } else {
            // No STATUS yet for this folder: zero the unread alone rather
            // than invent a total the badge would then draw as `0/0`.
            mailStore.counts.setUnreadCount(folderPath: folderPath, count: 0)
        }
        mailStore.requestListRefresh()
        return flipped
    }
}
