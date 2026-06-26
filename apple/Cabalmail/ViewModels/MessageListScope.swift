import CabalmailKit

/// What a `MessageListViewModel` / `MessageListView` is showing.
///
/// - `.folder` is the classic per-folder mailbox view: STATUS-driven counts,
///   positional pagination, the IDLE watcher, the on-disk envelope snapshot,
///   and the All / Unread / Flagged filter pills.
/// - `.search` is the global, cross-folder search surface. It has no anchor
///   folder, runs no folder lifecycle (no STATUS / pagination / IDLE / 60s
///   poll), and populates `envelopes` only via `runSearch`. Per-row source
///   folders come from `sourceFolderByUID`, so dispose / flag / move / read
///   still route to each result's true mailbox.
///
/// The view model keeps a resolved `folder` anchor either way (a sentinel for
/// `.search`) so the existing folder-keyed call sites compile unchanged; the
/// `.search` paths are gated off before any of them issue an IMAP request
/// against the sentinel.
enum MessageListScope: Equatable {
    case folder(Folder)
    case search

    /// Resolved anchor folder. `.search` has no real folder, so it yields a
    /// sentinel whose `path` is never sent to the server (search runs
    /// cross-folder and every result carries its own source folder).
    var folder: Folder {
        switch self {
        case .folder(let folder): return folder
        case .search: return Folder(path: "")
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}
