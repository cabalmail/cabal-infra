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
        if isSearchScope {
            content
        } else {
            content
                .toolbar {
                    ToolbarItem {
                        Menu {
                            markAllReadMenuItem
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
                .onChange(of: appState.markFolderReadRequestTick) { _, _ in
                    markAllReadConfirmPresented = true
                }
                // Tells the Mailbox menu which folder ⌥⌘T would act on; the
                // disappear is path-guarded because the list is re-keyed per
                // folder and the new list appears before the old one goes.
                .onAppear { appState.mailboxMenuAvailability.folderListAppeared(folder.path) }
                .onDisappear { appState.mailboxMenuAvailability.folderListDisappeared(folder.path) }
        }
    }

    /// Dimmed once the sidebar badge says the folder has nothing unread; a
    /// folder whose STATUS has not arrived stays live.
    private var markAllReadMenuItem: some View {
        Button {
            markAllReadConfirmPresented = true
        } label: {
            Label("Mark All as Read", systemImage: "envelope.open")
        }
        .disabled(model == nil || appState.folderUnreadCounts[folder.path] == 0)
        .accessibilityIdentifier("list.markAllRead")
    }
}
