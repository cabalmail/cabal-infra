import Foundation
import CabalmailKit

/// Mark All as Read, as the three surfaces that offer it call it: the
/// sidebar folder's context menu (`FolderListViewModel`), and the message
/// list's overflow menu and the Mailbox menu (`MessageListViewModel`). The
/// server call and every after-effect are the mutation service's
/// (`MailMutationService.markFolderRead`), so they can't drift between them.
@MainActor
enum FolderMarkAllRead {
    /// Returns how many messages the server flipped. Throws the transport or
    /// Lambda error for the caller to surface in its own `errorMessage`.
    @discardableResult
    static func perform(folderPath: String, client: CabalmailClient, mailStore: MailSessionStore) async throws -> Int {
        try await mailStore.mutations.markFolderRead(folderPath, through: client)
    }
}
