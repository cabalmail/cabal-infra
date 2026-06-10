import Foundation

/// Pure helpers over a flat `[Folder]` array that share the `/`-delimited
/// tree shape with the React rail in `react/admin/src/utils/folderMeta.js`.
/// Kept here (not on `FolderListViewModel`) so they're testable from
/// `swift test` and reused by both Apple targets.
public enum FolderTree {
    /// System folders sit at depth 0 regardless of any `/` in the name and
    /// are never themselves collapsible (they have no children in the tree).
    public static let systemPaths: Set<String> = [
        "INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive"
    ]

    /// Dovecot's special-use \Trash mailbox. Delete affordances switch to
    /// permanent deletion (purge / empty trash) when acting inside it.
    public static let trashPath = "Trash"

    /// DFS through the `/`-delimited tree formed by `path`s, emitting peers
    /// alphabetically and children directly under their parent. Intermediate
    /// path segments that aren't themselves in `input` are skipped - we
    /// don't fabricate rows for folders that aren't on the server.
    public static func sortUserTree(_ input: [Folder]) -> [Folder] {
        let byPath = Dictionary(uniqueKeysWithValues: input.map { ($0.path, $0) })
        var children: [String: [String]] = [:]
        var seen: [String: Set<String>] = [:]
        for folder in input {
            let segs = folder.path.split(separator: "/").map(String.init)
            var parent = ""
            for seg in segs {
                if seen[parent, default: []].insert(seg).inserted {
                    children[parent, default: []].append(seg)
                }
                parent = parent.isEmpty ? seg : "\(parent)/\(seg)"
            }
        }
        for key in children.keys {
            children[key]?.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        var out: [Folder] = []
        func walk(_ parent: String) {
            for seg in children[parent] ?? [] {
                let path = parent.isEmpty ? seg : "\(parent)/\(seg)"
                if let folder = byPath[path] {
                    out.append(folder)
                }
                walk(path)
            }
        }
        walk("")
        return out
    }

    /// Indentation depth for the "All folders" section - system folders
    /// (Inbox + Sent/Drafts/etc.) sit at depth 0 regardless of any `/` in
    /// the name; user folders indent one step per path segment past the
    /// root.
    public static func depth(for folder: Folder) -> Int {
        if systemPaths.contains(folder.path) { return 0 }
        return max(0, folder.path.split(separator: "/").count - 1)
    }

    /// True iff any other folder in `input` lives under `folder` in the tree.
    /// System folders never have collapsible children regardless of name.
    public static func hasChildren(_ folder: Folder, in input: [Folder]) -> Bool {
        if systemPaths.contains(folder.path) { return false }
        let prefix = folder.path + "/"
        return input.contains { $0.path != folder.path && $0.path.hasPrefix(prefix) }
    }

    /// Each `/`-delimited parent of `path`, e.g. "Work/Q1/Archive" ->
    /// ["Work", "Work/Q1"]. The path itself is not included.
    public static func ancestors(of path: String) -> [String] {
        let segs = path.split(separator: "/").map(String.init)
        guard segs.count > 1 else { return [] }
        var out: [String] = []
        var acc = ""
        for seg in segs.dropLast() {
            acc = acc.isEmpty ? seg : "\(acc)/\(seg)"
            out.append(acc)
        }
        return out
    }

    /// Filter `folders` so descendants of any path in `collapsed` are hidden,
    /// after first removing from `collapsed` any ancestor of `activeSelection`
    /// so the user's currently-open folder never disappears behind a stale
    /// collapse. Returns both the filtered list and the (possibly mutated)
    /// collapsed set so callers can persist the auto-expand.
    public static func visibleFolders(
        from folders: [Folder],
        collapsed: Set<String>,
        activeSelection: String?
    ) -> (visible: [Folder], collapsed: Set<String>) {
        var effective = collapsed
        if let active = activeSelection {
            for ancestor in ancestors(of: active) {
                effective.remove(ancestor)
            }
        }
        guard !effective.isEmpty else { return (folders, effective) }
        let present = Set(folders.map(\.path))
        let visible = folders.filter { folder in
            for ancestor in ancestors(of: folder.path) {
                if effective.contains(ancestor) && present.contains(ancestor) {
                    return false
                }
            }
            return true
        }
        return (visible, effective)
    }
}
