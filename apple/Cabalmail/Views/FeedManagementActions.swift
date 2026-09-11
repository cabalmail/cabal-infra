import SwiftUI
import CabalmailKit

/// Which management sheet or confirmation is up, plus the forms behind
/// them. Owned by the view that hosts `.feedManagementSheets` (the mail
/// sidebar on wide layouts, the Feeds tab's sidebar on compact, the item
/// list for its settings button), so the same presenter serves the `+`
/// menu, the row context menus, and the Feeds menu commands.
@Observable
@MainActor
final class FeedManagementActions {
    enum Sheet: Identifiable {
        case subscribe
        case folder
        case settings(RssSubscription)

        var id: String {
            switch self {
            case .subscribe: return "subscribe"
            case .folder: return "folder"
            case .settings(let sub): return "settings:\(sub.subscriptionId)"
            }
        }
    }

    var sheet: Sheet?
    var pendingFolderDelete: RssFolder?
    var pendingUnsubscribe: RssSubscription?
    /// A scope whose "Mark All as Read" awaits confirmation, with its name.
    var pendingMarkAllRead: (scope: RssItemScope, title: String)?

    let subscribeForm = SubscribeFeedForm()
    let folderForm = FeedFolderForm()
    let settingsForm = FeedSubscriptionSettingsForm()
    let opml = FeedOpmlController()

    func subscribe(in folderId: String? = nil) {
        subscribeForm.reset(folderId: folderId)
        sheet = .subscribe
    }

    func newFolder(in parentId: String? = nil) {
        folderForm.reset(editing: nil, parentId: parentId)
        sheet = .folder
    }

    func editFolder(_ folder: RssFolder) {
        folderForm.reset(editing: folder, parentId: nil)
        sheet = .folder
    }

    func settings(for subscription: RssSubscription) {
        settingsForm.load(from: subscription)
        sheet = .settings(subscription)
    }

    /// A Feeds menu command. Returns false for the one the host owns
    /// (refresh), so it can run its own sidebar refresh.
    func handle(_ command: FeedCommand, management: FeedManagementViewModel?) -> Bool {
        switch command {
        case .subscribe: subscribe()
        case .newFolder: newFolder()
        case .importOpml: opml.beginImport()
        case .exportOpml:
            guard let management else { return true }
            Task { await opml.beginExport(management: management) }
        case .refresh: return false
        }
        return true
    }
}

/// Presents the feed management sheets and confirmations for a host view,
/// keeps the feed selection valid when its target goes away, and routes the
/// Feeds menu commands when this host is the one that should answer them.
struct FeedManagementSheets: ViewModifier {
    let actions: FeedManagementActions
    let management: FeedManagementViewModel?
    let folders: [RssFolder]
    let subscriptions: [RssSubscription]
    @Binding var selection: RssItemScope?
    /// Exactly one mounted host answers the menu commands: the sidebar.
    var handlesCommands = false
    var onRefresh: () -> Void = {}
    var onSaved: (RssSubscription) -> Void = { _ in }
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        @Bindable var actions = actions
        content
            .sheet(item: $actions.sheet) { sheet in
                if let management { sheetView(sheet, management: management) }
            }
            .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
                Button("Delete Folder", role: .destructive) { deletePendingFolder() }
            } message: {
                Text("Feeds and folders inside it move up one level; nothing is unsubscribed.")
            }
            .confirmationDialog(unsubscribeTitle, isPresented: unsubscribeBinding, titleVisibility: .visible) {
                Button("Unsubscribe", role: .destructive) { unsubscribePending() }
            } message: {
                Text("Its items and your read and favorite marks for it are removed from this account.")
            }
            .confirmationDialog(markAllReadTitle, isPresented: markAllReadBinding, titleVisibility: .visible) {
                Button("Mark All as Read") { markAllReadPending() }
            } message: {
                Text("Items you have not opened will be marked read too.")
            }
            .feedOpmlFlows(actions.opml, management: management)
            .onChange(of: appState.feedCommandTick) { _, _ in
                guard handlesCommands, let command = appState.pendingFeedCommand else { return }
                if !actions.handle(command, management: management) { onRefresh() }
            }
            // The catalog changed under the selection (an unsubscribe from
            // the list's settings sheet, a folder deleted, another device):
            // a scope that no longer exists falls back to All Feeds.
            .onChange(of: catalogKeys) { _, _ in
                guard handlesCommands, let selection, !selection.exists(folders: folders, subscriptions: subscriptions)
                else { return }
                self.selection = .all
            }
    }

    private var catalogKeys: [String] {
        folders.map(\.folderId) + subscriptions.map(\.subscriptionId)
    }

    @ViewBuilder
    private func sheetView(_ sheet: FeedManagementActions.Sheet, management: FeedManagementViewModel) -> some View {
        switch sheet {
        case .subscribe:
            SubscribeFeedSheet(form: actions.subscribeForm, folders: folders, management: management) { result in
                selection = .subscription(result.subscription.subscriptionId)
            }
        case .folder:
            FeedFolderSheet(form: actions.folderForm, folders: folders, management: management) { _ in }
        case .settings(let subscription):
            FeedSubscriptionSettingsSheet(
                subscription: subscription, form: actions.settingsForm, folders: folders, management: management,
                onSaved: onSaved,
                onUnsubscribed: { sub in dropSelection(.subscription(sub.subscriptionId)) }
            )
        }
    }

    private var deleteTitle: String {
        "Delete \(actions.pendingFolderDelete?.name ?? "folder")?"
    }

    private var unsubscribeTitle: String {
        "Unsubscribe from \(actions.pendingUnsubscribe?.displayTitle ?? "this feed")?"
    }

    private var markAllReadTitle: String {
        "Mark all items in \(actions.pendingMarkAllRead?.title ?? "these feeds") as read?"
    }

    private var markAllReadBinding: Binding<Bool> {
        Binding(get: { actions.pendingMarkAllRead != nil },
                set: { if !$0 { actions.pendingMarkAllRead = nil } })
    }

    private func markAllReadPending() {
        guard let pending = actions.pendingMarkAllRead, let management else { return }
        actions.pendingMarkAllRead = nil
        Task {
            do { try await management.markAllRead(scope: pending.scope) } catch {
                actions.opml.resultMessage = FeedErrorText.describe(error)
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { actions.pendingFolderDelete != nil },
                set: { if !$0 { actions.pendingFolderDelete = nil } })
    }

    private var unsubscribeBinding: Binding<Bool> {
        Binding(get: { actions.pendingUnsubscribe != nil },
                set: { if !$0 { actions.pendingUnsubscribe = nil } })
    }

    private func deletePendingFolder() {
        guard let folder = actions.pendingFolderDelete, let management else { return }
        actions.pendingFolderDelete = nil
        Task {
            do {
                _ = try await management.deleteFolder(folder)
                dropSelection(.folder(folder.folderId))
            } catch {
                actions.opml.resultMessage = FeedErrorText.describe(error)
            }
        }
    }

    private func unsubscribePending() {
        guard let subscription = actions.pendingUnsubscribe, let management else { return }
        actions.pendingUnsubscribe = nil
        Task {
            do {
                try await management.unsubscribe(subscription)
                dropSelection(.subscription(subscription.subscriptionId))
            } catch {
                actions.opml.resultMessage = FeedErrorText.describe(error)
            }
        }
    }

    /// The selected scope just went away: fall back to All Feeds rather
    /// than leave the list pointed at nothing.
    private func dropSelection(_ gone: RssItemScope) {
        if selection == gone { selection = .all }
    }
}

extension View {
    func feedManagementSheets(
        _ actions: FeedManagementActions,
        management: FeedManagementViewModel?,
        folders: [RssFolder],
        subscriptions: [RssSubscription] = [],
        selection: Binding<RssItemScope?>,
        handlesCommands: Bool = false,
        onRefresh: @escaping () -> Void = {},
        onSaved: @escaping (RssSubscription) -> Void = { _ in }
    ) -> some View {
        modifier(FeedManagementSheets(actions: actions, management: management, folders: folders,
                                      subscriptions: subscriptions, selection: selection,
                                      handlesCommands: handlesCommands, onRefresh: onRefresh, onSaved: onSaved))
    }
}

extension RssItemScope {
    /// Whether the scope still points at something in the catalog.
    func exists(folders: [RssFolder], subscriptions: [RssSubscription]) -> Bool {
        switch self {
        case .all: return true
        case .folder(let id): return folders.contains { $0.folderId == id }
        case .subscription(let id): return subscriptions.contains { $0.subscriptionId == id }
        }
    }
}

/// The `+` menu beside the Feeds header (wide sidebar) and in the Feeds
/// tab's toolbar (compact): the four ways a subscription list changes.
struct FeedAddMenu: View {
    let actions: FeedManagementActions
    let management: FeedManagementViewModel?

    var body: some View {
        Menu {
            Button {
                actions.subscribe()
            } label: {
                Label("Subscribe to Feed…", systemImage: "plus.circle")
            }
            Button {
                actions.newFolder()
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            Divider()
            Button {
                actions.opml.beginImport()
            } label: {
                Label("Import OPML…", systemImage: "square.and.arrow.down")
            }
            Button {
                guard let management else { return }
                Task { await actions.opml.beginExport(management: management) }
            } label: {
                Label("Export OPML…", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "plus")
                .accessibilityLabel("Add feed or folder")
        }
        .disabled(management == nil)
        .accessibilityIdentifier("feeds.add")
    }
}
