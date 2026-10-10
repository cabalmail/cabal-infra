import SwiftUI
import CabalmailKit

// Mark All as Read for the folder the list is showing (cross-media plan,
// Phase 1): the toolbar's More menu entry, the Mailbox menu's ⌥⌘T arriving
// as `markFolderReadRequestTick`, and the confirmation both go through. A
// sibling extension so the primary MessageListView body stays under
// SwiftLint's `type_body_length` cap, like `+FolderSwitch`.
//
// The search surface has no folder to mark: it gets no menu entry, ignores
// the tick, and reports no front folder, which is what dims the Mailbox item
// there (`MailboxMenuAvailability.canMarkAllRead`).
extension MessageListView {
    /// Hangs the confirmation, the chord consumer and the front-folder report
    /// on `content`. The More menu is a separate toolbar item so it composes
    /// with the compose / refresh items the main body declares.
    @ViewBuilder
    func markAllReadChrome<Content: View>(_ content: Content) -> some View {
        if let folder {
            content
                .toolbar {
                    ToolbarItem {
                        Menu {
                            markAllReadMenuItem(in: folder)
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("list.more")
                    }
                }
                // Same wording as the sidebar's dialog and the feed side's
                // `confirmMarkAllRead`: the folder is named, the verb is the
                // button. Not destructive — a read mark is reversible.
                .confirmationDialog("Mark all messages in \(folder.name) as read?",
                                    isPresented: $markAllReadConfirmPresented, titleVisibility: .visible) {
                    Button("Mark All as Read") { Task { await model?.markAllRead() } }
                    Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {}
                } message: {
                    Text("Every unread message in the folder is marked read, in one step.")
                }
                .onWindowCommand(appState.markFolderReadRequestTick) {
                    markAllReadConfirmPresented = true
                }
                // Tells the Mailbox menu which folder ⌥⌘T would act on.
                .reportsMailboxFolder(folder.path)
        } else {
            content
        }
    }

    /// Dimmed once the sidebar badge says the folder has nothing unread; a
    /// folder whose STATUS has not arrived stays live.
    private func markAllReadMenuItem(in folder: Folder) -> some View {
        Button {
            markAllReadConfirmPresented = true
        } label: {
            Label("Mark All as Read", systemImage: "envelope.open")
        }
        .disabled(model == nil || appState.mailStore.counts.folderUnreadCounts[folder.path] == 0)
        .accessibilityIdentifier("list.markAllRead")
    }
}
