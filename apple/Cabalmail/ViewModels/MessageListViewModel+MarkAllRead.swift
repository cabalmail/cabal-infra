import Foundation
import CabalmailKit

// Mark All as Read from the message list's own chrome (the toolbar's More
// menu and the Mailbox menu's ⌥⌘T), for the folder the list is showing. A
// sibling extension like `+Purge` so the primary class body stays under
// SwiftLint's `type_body_length` cap.
extension MessageListViewModel {
    /// Same server call and after-effects as the sidebar's entry
    /// (`FolderListViewModel.markAllRead(folderPath:)`); the `requestRefresh`
    /// inside `FolderMarkAllRead` is what hard-reloads this very list.
    func markAllRead() async {
        do {
            try await FolderMarkAllRead.perform(folderPath: folder.path, client: client, appState: appState)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
