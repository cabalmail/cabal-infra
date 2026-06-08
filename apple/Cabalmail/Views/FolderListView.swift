import SwiftUI
import CabalmailKit

/// Folder sidebar (Phase 4 step 3).
///
/// Selecting a folder pushes a `MessageListView` in the iPhone `NavigationStack`
/// and replaces the middle column in the iPad/macOS/visionOS split view. The
/// selection state is owned here so the parent split view can bind to it.
struct FolderListView: View {
    // Properties without `private` are reachable from the same-type
    // extensions in `FolderListView+Helpers.swift`; the others stay
    // file-local. Matches the access discipline used by
    // `MessageListView` and its `+Bulk` / `+Search` / `+macOS`
    // extensions in this directory.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) var preferences
    @State var model: FolderListViewModel?
    @State private var didNotifyLoad = false
    @State var filterQuery: String = ""
    @State var isRefreshing = false
    @Binding var selection: Folder?
    /// Called exactly once, the first time the folder list successfully
    /// loads. `MailRootView` uses it to seed a default `selection` so the
    /// signed-in user doesn't land on an empty "pick a mailbox" screen
    /// (which would also hide the compose entry point on the message list).
    var onFoldersLoaded: ([Folder]) -> Void = { _ in }

    // Section expand/collapse state - persisted so the sidebar comes up the
    // way the user left it. Subscribed defaults open (that's where the
    // user's attention lives); "All folders" defaults collapsed because
    // it's a long list of folders the user has explicitly opted out of
    // proactive tracking on.
    @AppStorage("cabalmail.folder.section.subscribed.expanded")
    private var subscribedExpanded: Bool = true
    @AppStorage("cabalmail.folder.section.all.expanded")
    private var allExpanded: Bool = false
    // Per-folder collapse state. Stored as a newline-joined string because
    // @AppStorage doesn't natively support Set; folder paths cannot contain
    // newlines so this is unambiguous.
    @AppStorage("cabalmail.folder.collapsedPaths")
    var collapsedPathsRaw: String = ""
    // Folder path currently under a message drag, or nil. Drives the drop-
    // target border in `folderRow` and is toggled by each selectable folder's
    // `.onDrop(isTargeted:)` binding. Non-private so the `+Helpers` extension
    // that builds the drop modifier and handler can reach it.
    @State var dropTargetPath: String?

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
                    RefreshActivityIcon(isLoading: isRefreshing)
                        .accessibilityLabel("Refresh folders")
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
                // Race the inbox STATUS against the folder list so the
                // inbox badge is correct by the time the user's eyes
                // reach it — the message list itself starts loading the
                // moment `onFoldersLoaded` fires below, so anything we
                // can finish before then is free.
                async let inbox: () = newModel.refreshInboxCount()
                await newModel.loadFolderList()
                _ = await inbox
                if !didNotifyLoad, !newModel.folders.isEmpty {
                    didNotifyLoad = true
                    onFoldersLoaded(newModel.folders)
                }
                // Back-fill the rest of the subscribed folders'
                // counts. Unsubscribed folders are fetched lazily by
                // `lazyFetchCountIfNeeded` when the user selects one.
                await newModel.refreshSubscribedCounts()
            }
        }
        .onChange(of: selection?.path) { _, newPath in
            autoExpandAncestors(of: newPath)
            lazyFetchCountIfNeeded(path: newPath)
        }
    }

    @ViewBuilder
    private func folderRow(
        _ folder: Folder,
        model: FolderListViewModel,
        depth: Int,
        collapsed: Set<String>
    ) -> some View {
        // `\Noselect` containers can't hold messages, so they're not drop
        // targets (mirrors MoveToFolderSheet's filter). Selectable folders
        // get an `.onDrop` + an accent border while a drag hovers them.
        let isDroppable = !folder.attributes.contains("\\Noselect")
        withFolderDrop(folder, droppable: isDroppable) {
        row(
            for: folder,
            badge: countBadgeText(
                unread: appState.folderUnreadCounts[folder.path],
                total: appState.folderTotalCounts[folder.path]
            ),
            depth: depth,
            hasChildren: model.hasChildren(folder),
            isCollapsed: collapsed.contains(folder.path)
        )
            .tag(folder)
            .overlay {
                if dropTargetPath == folder.path {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 2)
                }
            }
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
    }

    @ViewBuilder
    private func row(
        for folder: Folder,
        badge: String?,
        depth: Int,
        hasChildren: Bool,
        isCollapsed: Bool
    ) -> some View {
        let isSelected = selection?.path == folder.path
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
                // iPadOS sidebar selection paints the row in the accent color,
                // so a tinted icon vanishes against the highlight. Flip to
                // white when selected to keep it readable. macOS uses a
                // translucent gray selection that already contrasts, so leave
                // it on the regular tint.
                .foregroundStyle(iconForeground(isSelected: isSelected))
            Text(folder.name)
            Spacer()
            if let badge {
                Text(badge)
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

}
