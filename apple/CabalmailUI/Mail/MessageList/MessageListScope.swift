import CabalmailKit

/// What a `MessageListViewModel` / `MessageListView` is showing.
///
/// - `.folder` is the classic per-folder mailbox view: STATUS-driven counts,
///   positional pagination, the change watcher, the on-disk envelope snapshot,
///   and the All / Unread / Flagged filter pills.
/// - `.search` is the global, cross-folder search surface. It shows no folder:
///   its list has no folder window, and its rows come only from a search, each
///   carrying its own folder (`Envelope.folder`), so dispose / flag / move /
///   read still route to each result's true mailbox.
enum MessageListScope: Equatable {
    case folder(Folder)
    case search

    /// The folder a folder list shows; nil for the search surface, which shows
    /// none.
    var folder: Folder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}
