import SwiftUI
import CabalmailKit

/// Context menu for a Feeds sidebar row: folders get subscribe-here, new
/// subfolder, rename/move, mark all read, delete; subscriptions get
/// settings, mark all read, open site, unsubscribe. "All Feeds" (a nil row
/// kind) gets mark all read alone.
struct FeedSidebarContextMenu: View {
    let scope: RssItemScope
    let row: FeedSidebarRow?
    let actions: FeedManagementActions
    let management: FeedManagementViewModel?

    var body: some View {
        Group {
            switch row?.kind {
            case .folder(let folder): folderItems(folder)
            case .subscription(let subscription): subscriptionItems(subscription)
            case nil: markAllRead
            }
        }
    }

    @ViewBuilder
    private func folderItems(_ folder: RssFolder) -> some View {
        Button {
            actions.subscribe(in: folder.folderId)
        } label: {
            Label("Subscribe to Feed Here…", systemImage: "plus.circle")
        }
        Button {
            actions.newFolder(in: folder.folderId)
        } label: {
            Label("New Folder Inside…", systemImage: "folder.badge.plus")
        }
        Divider()
        Button {
            actions.editFolder(folder)
        } label: {
            Label("Rename or Move…", systemImage: "pencil")
        }
        markAllRead
        Divider()
        Button(role: .destructive) {
            actions.pendingFolderDelete = folder
        } label: {
            Label("Delete Folder…", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func subscriptionItems(_ subscription: RssSubscription) -> some View {
        Button {
            actions.settings(for: subscription)
        } label: {
            Label("Feed Settings…", systemImage: "gearshape")
        }
        markAllRead
        if let site = subscription.feed?.siteUrl, let url = URL(string: site), !site.isEmpty {
            Link(destination: url) {
                Label("Open Site", systemImage: "safari")
            }
        }
        Divider()
        Button(role: .destructive) {
            actions.pendingUnsubscribe = subscription
        } label: {
            Label("Unsubscribe…", systemImage: "minus.circle")
        }
    }

    private var markAllRead: some View {
        Button {
            actions.pendingMarkAllRead = (scope, row?.title ?? "All Feeds")
        } label: {
            Label("Mark All as Read", systemImage: "envelope.open")
        }
        .disabled(management == nil)
    }
}
