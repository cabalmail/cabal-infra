import SwiftUI
import CabalmailKit

/// Pure helpers split off from `FolderListView` so the main struct body
/// stays under the SwiftLint type-body cap. Extensions on the same type
/// in the same module share `private` scope with the original
/// declaration — these helpers continue to see `@AppStorage`, `@State`,
/// and `@Environment` properties as if they were inline.
extension FolderListView {
    func manualRefresh() async {
        guard let model, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await model.refresh()
    }

    /// Wide-sidebar header row (New / filter / Reload), shown below the
    /// Folders/Addresses tabs on iPad-regular and macOS. Lifted here so the
    /// main `FolderListView` body stays under the type-body-length cap.
    func wideSidebarHeader(filter: Binding<String>) -> some View {
        SidebarListHeaderRow(
            newAction: { presentNewFolderSheet() },
            newDisabled: model == nil,
            newAccessibilityLabel: "New folder",
            newIdentifier: "folder.new",
            filterText: filter,
            filterPrompt: "Filter folders",
            isRefreshing: isRefreshing,
            refreshDisabled: isRefreshing || model == nil,
            refreshAccessibilityLabel: "Refresh folders",
            refreshIdentifier: "folder.refresh",
            refreshAction: { Task { await manualRefresh() } }
        )
    }

    /// A sidebar section header carrying its own disclosure control.
    ///
    /// `Section(_:isExpanded:)` draws no visible one on any of the three
    /// platforms (#1184), so the header draws the chevron the folder rows
    /// already use — same glyph, same rotation, same "Expand X" / "Collapse X"
    /// phrasing — and `FolderSectionDisclosure` decides what the section
    /// shows. The binding arrives as a parameter because the `@AppStorage`
    /// properties behind it are `private` to `FolderListView.swift`.
    func sectionHeader(_ title: String, key: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .rotationEffect(
                        .degrees(FolderSectionDisclosure.chevronRotation(isExpanded: isExpanded.wrappedValue))
                    )
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                Text(title)
                Spacer()
            }
            // The header spans the sidebar but its glyph and word occupy the
            // first inch of it; without this the transparent remainder is not
            // a tap target, which in a sidebar is most of the control.
            .contentShape(Rectangle())
        }
        // Plain keeps the header looking like list chrome rather than a
        // control; borderless (what the row chevrons use) is about not
        // triggering the surrounding row's selection, and a header has none.
        .buttonStyle(.plain)
        .accessibilityLabel(
            FolderSectionDisclosure.accessibilityLabel(title: title, isExpanded: isExpanded.wrappedValue)
        )
        .accessibilityIdentifier("folder.section.disclose.\(key)")
    }

    /// Raises the "New folder" sheet from an empty form. The form outlives
    /// the sheet (see `newFolderForm`), so it is cleared on the way in rather
    /// than by the sheet's own state going away.
    func presentNewFolderSheet() {
        newFolderForm.reset()
        showNewFolderSheet = true
    }

    func filteredFolders(_ folders: [Folder]) -> [Folder] {
        let needle = activeFilterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return folders }
        return folders.filter { folder in
            folder.path.lowercased().contains(needle)
                || folder.name.lowercased().contains(needle)
        }
    }

    func decodeCollapsed() -> Set<String> {
        guard !collapsedPathsRaw.isEmpty else { return [] }
        return Set(collapsedPathsRaw.split(separator: "\n").map(String.init))
    }

    func encodeCollapsed(_ set: Set<String>) -> String {
        set.sorted().joined(separator: "\n")
    }

    func toggleCollapse(_ path: String) {
        var set = decodeCollapsed()
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        collapsedPathsRaw = encodeCollapsed(set)
    }

    func autoExpandAncestors(of path: String?) {
        guard let path else { return }
        var set = decodeCollapsed()
        var changed = false
        for ancestor in FolderTree.ancestors(of: path) where set.remove(ancestor) != nil {
            changed = true
        }
        if changed { collapsedPathsRaw = encodeCollapsed(set) }
    }

    func iconForeground(isSelected: Bool) -> AnyShapeStyle {
        // Folder icons carry the brand accent from the asset catalog,
        // pinned explicitly rather than ridden through `.tint`: macOS
        // repaints environment tints with the user's system accent
        // (System Settings > Appearance) whenever that isn't
        // "multicolor", which left the wide layouts' icons off-brand.
        // The pinned color resolves the same light/dark variants on
        // every platform, so compact renders identically to before.
        #if os(macOS)
        return AnyShapeStyle(Color("AccentColor"))
        #else
        return isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color("AccentColor"))
        #endif
    }

    /// Foreground for the folder name: accent while the folder has
    /// unread messages, dimmed to secondary once it's caught up. Uses
    /// the same pinned asset-catalog accent and selected-row white
    /// flip as `iconForeground` (see the tint note there).
    func folderNameForeground(hasUnread: Bool, isSelected: Bool) -> AnyShapeStyle {
        #if !os(macOS)
        if isSelected { return AnyShapeStyle(Color.white) }
        #endif
        return hasUnread ? AnyShapeStyle(Color("AccentColor")) : AnyShapeStyle(.secondary)
    }

    /// Render the count badge text honoring the user's
    /// `folderCountDisplay` preference. Returns `nil` when nothing
    /// should be shown so the badge capsule collapses entirely (no
    /// stray "0" badges on read folders).
    func countBadgeText(unread: Int?, total: Int?) -> String? {
        switch preferences.folderCountDisplay {
        case .unread:
            guard let unread, unread > 0 else { return nil }
            return "\(unread)"
        case .total:
            guard let total, total > 0 else { return nil }
            return "\(total)"
        case .both:
            // For folders whose counts haven't been fetched yet we
            // suppress the badge entirely rather than render `0/0`,
            // which looks like a real (and confusing) zero-mailbox.
            guard let total else { return nil }
            return "\(unread ?? 0)/\(total)"
        }
    }

    /// Fire a one-shot STATUS for an unsubscribed folder the user just
    /// selected, so the row's badge stops being blank. Subscribed
    /// folders are already covered by the launch-time walk; INBOX is
    /// always refreshed; other-already-known counts are skipped to
    /// avoid hammering the Lambda every time the user clicks back to
    /// a folder they've already visited.
    func lazyFetchCountIfNeeded(path: String?) {
        guard let path, let model else { return }
        if appState.folderUnreadCounts[path] != nil { return }
        guard let folder = model.folders.first(where: { $0.path == path }),
              !folder.isSubscribed
        else { return }
        Task { await model.refreshFolderCount(path: path) }
    }

    /// Wrap a folder row in `.dropDestination` so messages can be dragged onto
    /// it. `\Noselect` containers pass `droppable: false` and get no drop
    /// target. The `isTargeted` callback drives `dropTargetPath`, which
    /// `folderRow` reads to draw the accent border on the folder under the
    /// drag.
    @ViewBuilder
    func withFolderDrop(
        _ folder: Folder,
        droppable: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if droppable {
            content().dropDestination(for: MessageDragPayload.self) { payloads, _ in
                handleMessageDrop(payloads, into: folder)
            } isTargeted: { isIn in
                if isIn {
                    dropTargetPath = folder.path
                } else if dropTargetPath == folder.path {
                    dropTargetPath = nil
                }
            }
        } else {
            content()
        }
    }

    /// Post a move request for the active message list to perform. SwiftUI
    /// decodes the `Transferable` payload before calling this, so we just
    /// flatten the items and route them. `endMessageDrag()` always runs so
    /// the sidebar flips back from folders to addresses once the drop lands.
    func handleMessageDrop(_ payloads: [MessageDragPayload], into folder: Folder) -> Bool {
        defer { appState.endMessageDrag() }
        let items = payloads.flatMap { $0.items }
        guard !items.isEmpty else { return false }
        appState.requestMove(items: items, to: folder.path)
        return true
    }

    func iconName(for folder: Folder) -> String {
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

    // MARK: - Folder row affordances

    /// Trailing swipe actions for a folder row: delete (user folders only) and
    /// the subscribe/unsubscribe toggle. Split out of `folderRow` to keep that
    /// function under the SwiftLint body-length cap.
    @ViewBuilder
    func folderSwipeActions(_ folder: Folder, model: FolderListViewModel) -> some View {
        if model.canDelete(folder) {
            Button(role: .destructive) {
                pendingDelete = folder
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier("folder.swipe.delete")
        }
        Button {
            Task { await model.toggleSubscription(folder) }
        } label: {
            Label(
                folder.isSubscribed ? "Unsubscribe" : "Subscribe",
                systemImage: folder.isSubscribed ? "bell.slash" : "bell"
            )
        }
        .tint(folder.isSubscribed ? .orange : .accentColor)
        .accessibilityIdentifier("folder.swipe.subscribe")
    }

    /// Context menu for a folder row: subscribe toggle, Empty Trash (Trash
    /// only), and delete (user folders only).
    @ViewBuilder
    func folderContextMenu(_ folder: Folder, model: FolderListViewModel) -> some View {
        Button {
            Task { await model.toggleSubscription(folder) }
        } label: {
            Label(
                folder.isSubscribed ? "Unsubscribe" : "Subscribe",
                systemImage: folder.isSubscribed ? "bell.slash" : "bell"
            )
        }
        if folder.path == FolderTree.trashPath {
            Button(role: .destructive) {
                emptyTrashConfirmPresented = true
            } label: {
                Label("Empty Trash", systemImage: "trash.slash")
            }
        }
        if model.canDelete(folder) {
            Button(role: .destructive) {
                pendingDelete = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    // MARK: - New-folder sheet / delete-dialog plumbing

    @ViewBuilder
    var newFolderSheet: some View {
        if let model {
            NewFolderSheet(parents: model.possibleParents, form: newFolderForm) { name, parent in
                await model.createFolder(name: name, parent: parent)
            }
        }
    }

    var deleteDialogTitle: String {
        if let folder = pendingDelete {
            return "Delete \(folder.path)?"
        }
        return "Delete folder?"
    }

    var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented { pendingDelete = nil }
            }
        )
    }

    @ViewBuilder
    func deleteDialogActions(for folder: Folder) -> some View {
        Button("Delete", role: .destructive) {
            let target = folder
            pendingDelete = nil
            Task {
                guard let model, await model.deleteFolder(target) else { return }
                // The row is gone from the sidebar, but the selection the
                // split view binds to is ours to move — left alone it keeps
                // the message list pointed at a folder the server no longer
                // has (#1062).
                selection = FolderSelectionRecovery.selection(
                    current: selection,
                    remaining: model.folders
                )
            }
        }
        Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {
            pendingDelete = nil
        }
    }

    @ViewBuilder
    func deleteDialogMessage(for folder: Folder) -> some View {
        Text("Messages inside \(folder.path) will be deleted by the server. This can't be undone.")
    }
}
