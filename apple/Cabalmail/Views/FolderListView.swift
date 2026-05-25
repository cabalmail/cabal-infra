import SwiftUI
import CabalmailKit

/// Folder sidebar (Phase 4 step 3).
///
/// Selecting a folder pushes a `MessageListView` in the iPhone `NavigationStack`
/// and replaces the middle column in the iPad/macOS/visionOS split view. The
/// selection state is owned here so the parent split view can bind to it.
struct FolderListView: View {
    @Environment(AppState.self) private var appState
    @State private var model: FolderListViewModel?
    @State private var didNotifyLoad = false
    @State private var filterQuery: String = ""
    @State private var isRefreshing = false
    @Binding var selection: Folder?
    /// Called exactly once, the first time the folder list successfully
    /// loads. `MailRootView` uses it to seed a default `selection` so the
    /// signed-in user doesn't land on an empty "pick a mailbox" screen
    /// (which would also hide the compose entry point on the message list).
    var onFoldersLoaded: ([Folder]) -> Void = { _ in }

    // Section expand/collapse state - persisted so the sidebar comes up the
    // way the user left it. Default expanded.
    @AppStorage("cabalmail.folder.section.subscribed.expanded")
    private var subscribedExpanded: Bool = true
    @AppStorage("cabalmail.folder.section.all.expanded")
    private var allExpanded: Bool = true
    // Per-folder collapse state. Stored as a newline-joined string because
    // @AppStorage doesn't natively support Set; folder paths cannot contain
    // newlines so this is unambiguous.
    @AppStorage("cabalmail.folder.collapsedPaths")
    private var collapsedPathsRaw: String = ""

    var body: some View {
        let collapsedSet = decodeCollapsed()
        List(selection: $selection) {
            if let model {
                if model.isLoading && model.folders.isEmpty {
                    ProgressView("Loading folders…")
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                let subscribed = filteredFolders(model.subscribedFolders)
                let all = filteredFolders(model.folders)
                let (visibleAll, _) = FolderTree.visibleFolders(
                    from: all,
                    collapsed: collapsedSet,
                    activeSelection: selection?.path
                )
                if !model.subscribedFolders.isEmpty {
                    DisclosureGroup(isExpanded: $subscribedExpanded) {
                        ForEach(subscribed, id: \.path) { folder in
                            folderRow(folder, model: model, depth: 0, collapsed: collapsedSet)
                        }
                    } label: {
                        Text("Subscribed")
                    }
                    DisclosureGroup(isExpanded: $allExpanded) {
                        ForEach(visibleAll, id: \.path) { folder in
                            folderRow(
                                folder,
                                model: model,
                                depth: model.depth(for: folder),
                                collapsed: collapsedSet
                            )
                        }
                    } label: {
                        Text("All folders")
                    }
                } else {
                    ForEach(visibleAll, id: \.path) { folder in
                        folderRow(
                            folder,
                            model: model,
                            depth: model.depth(for: folder),
                            collapsed: collapsedSet
                        )
                    }
                }
            }
        }
        .navigationTitle("Mailboxes")
        .searchable(text: $filterQuery, placement: .sidebar, prompt: "Filter folders")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await manualRefresh() }
                } label: {
                    if isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .accessibilityLabel("Refresh folders")
                    }
                }
                .disabled(isRefreshing || model == nil)
            }
        }
        .refreshable {
            await model?.refresh()
        }
        // Sign-out used to live here; Phase 6's Settings tab is the
        // canonical place for it now. Leaving a duplicate confused the UI —
        // the Mailboxes toolbar is about mailbox navigation, not account
        // state.
        .task {
            if model == nil, let client = appState.client {
                let newModel = FolderListViewModel(client: client, appState: appState)
                model = newModel
                // Fetch + publish the folder list, then notify the parent so
                // it can seed Inbox selection immediately. The unread-count
                // walk runs afterwards in the background, so badges fill in
                // without blocking the message list from loading.
                await newModel.loadFolderList()
                if !didNotifyLoad, !newModel.folders.isEmpty {
                    didNotifyLoad = true
                    onFoldersLoaded(newModel.folders)
                }
                await newModel.refreshUnreadCounts()
            }
        }
        .onChange(of: selection?.path) { _, newPath in
            autoExpandAncestors(of: newPath)
        }
    }

    private func manualRefresh() async {
        guard let model, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refresh()
    }

    private func filteredFolders(_ folders: [Folder]) -> [Folder] {
        let needle = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return folders }
        return folders.filter { folder in
            folder.path.lowercased().contains(needle)
                || folder.name.lowercased().contains(needle)
        }
    }

    private func decodeCollapsed() -> Set<String> {
        guard !collapsedPathsRaw.isEmpty else { return [] }
        return Set(collapsedPathsRaw.split(separator: "\n").map(String.init))
    }

    private func encodeCollapsed(_ set: Set<String>) -> String {
        set.sorted().joined(separator: "\n")
    }

    private func toggleCollapse(_ path: String) {
        var set = decodeCollapsed()
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        collapsedPathsRaw = encodeCollapsed(set)
    }

    private func autoExpandAncestors(of path: String?) {
        guard let path else { return }
        var set = decodeCollapsed()
        var changed = false
        for ancestor in FolderTree.ancestors(of: path) where set.remove(ancestor) != nil {
            changed = true
        }
        if changed { collapsedPathsRaw = encodeCollapsed(set) }
    }

    @ViewBuilder
    private func folderRow(
        _ folder: Folder,
        model: FolderListViewModel,
        depth: Int,
        collapsed: Set<String>
    ) -> some View {
        row(
            for: folder,
            unread: appState.folderUnreadCounts[folder.path] ?? 0,
            depth: depth,
            hasChildren: model.hasChildren(folder),
            isCollapsed: collapsed.contains(folder.path)
        )
            .tag(folder)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    Task { await model.toggleSubscription(folder) }
                } label: {
                    Label(
                        folder.isSubscribed ? "Unsubscribe" : "Subscribe",
                        systemImage: folder.isSubscribed ? "bell.slash" : "bell"
                    )
                }
                .tint(folder.isSubscribed ? .orange : .accentColor)
            }
            .contextMenu {
                Button {
                    Task { await model.toggleSubscription(folder) }
                } label: {
                    Label(
                        folder.isSubscribed ? "Unsubscribe" : "Subscribe",
                        systemImage: folder.isSubscribed ? "bell.slash" : "bell"
                    )
                }
            }
    }

    @ViewBuilder
    private func row(
        for folder: Folder,
        unread: Int,
        depth: Int,
        hasChildren: Bool,
        isCollapsed: Bool
    ) -> some View {
        HStack {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth) * 14)
            }
            // Always reserve the chevron slot so the folder icon column
            // stays aligned across leaf and parent rows at the same depth.
            // Without the placeholder, parent rows shift right by the
            // chevron's width and visually read as one indent level deeper
            // than their peers.
            Group {
                if hasChildren {
                    Button {
                        toggleCollapse(folder.path)
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            .foregroundStyle(.secondary)
                    }
                    // Borderless lets the chevron handle taps without also
                    // triggering row selection in the surrounding List.
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isCollapsed ? "Expand \(folder.name)" : "Collapse \(folder.name)")
                } else {
                    Color.clear
                }
            }
            .frame(width: 14, height: 14)
            Image(systemName: iconName(for: folder))
                .foregroundStyle(.tint)
            Text(folder.name)
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        #if os(visionOS)
        // visionOS spatial UIs want an explicit hover affordance — eye-
        // tracking highlights the row before the user commits with a pinch,
        // and the default list row doesn't provide that feedback out of the
        // box. `.hoverEffect(.highlight)` matches Apple Mail on visionOS.
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        #endif
    }

    private func iconName(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "doc"
        case "Trash":   return "trash"
        case "Junk":    return "xmark.bin"
        case "Archive": return "archivebox"
        default:        return "folder"
        }
    }
}
