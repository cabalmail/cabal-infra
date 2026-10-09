import Foundation
import CabalmailKit

// Mark All as Read from the message list's own chrome (the toolbar's More
// menu and the Mailbox menu's ⌥⌘T), for the folder the list is showing. A
// sibling extension like `+Purge` so the primary class body stays under
// SwiftLint's `type_body_length` cap.
extension MessageListViewModel {
    /// Same server call and after-effects as the sidebar's entry
    /// (`FolderListViewModel.markAllRead(folderPath:)`); the list reload
    /// `MailMutationService.markFolderRead` asks for is what hard-reloads this
    /// very list. The search surface has no folder to mark.
    func markAllRead() async {
        guard let folder else { return }
        do {
            try await FolderMarkAllRead.perform(folderPath: folder.path, client: client, mailStore: mailStore)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
