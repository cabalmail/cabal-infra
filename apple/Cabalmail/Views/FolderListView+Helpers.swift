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

    func filteredFolders(_ folders: [Folder]) -> [Folder] {
        let needle = filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
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
        #if os(macOS)
        return AnyShapeStyle(.tint)
        #else
        return isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.tint)
        #endif
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
}
