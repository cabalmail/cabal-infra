import Foundation
import CabalmailKit

// Permanent deletion out of Trash for the detail pane. Sibling extension
// for the same reason as `+Flags`: keeps the main view-model file under
// SwiftLint's caps. Mirrors `dispose(action:onFailure:)`'s optimistic
// shape minus the `\Seen` mark — an expunged message has no flags left
// to maintain.
extension MessageDetailViewModel {
    /// True when the open message lives in the Trash folder; the toolbar's
    /// delete button switches to "delete forever" + confirmation.
    var isTrashFolder: Bool { folder.path == FolderTree.trashPath }

    /// What the toolbar's dispose button means for the open message, and
    /// what the overflow menu's alternate destination means when it lands
    /// on Archive. Shares `DisposeIntent` with the list surfaces so the
    /// reader and the row agree on Delete Forever / Restore.
    var disposeIntent: DisposeIntent {
        .standard(preference: disposeAction, in: folder.path)
    }

    var archiveIntent: DisposeIntent {
        .archiving(in: folder.path)
    }

    /// The intent a dispose-options row runs for an explicitly chosen
    /// destination, reconciled with the open folder like the toolbar
    /// default: archiving keeps its Restore / rescue-from-Trash special
    /// cases, and an explicit Delete inside Trash is the delete-forever
    /// path.
    func intent(for action: DisposeAction) -> DisposeIntent {
        switch action {
        case .archive: return archiveIntent
        case .trash:   return .standard(preference: .trash, in: folder.path)
        }
    }

    /// Deletes the open message for good, once the user has confirmed.
    /// Optimistic like `dispose`: every list drops the row at once and puts
    /// it back if the server refuses, when `onFailure` shows the toast.
    func purge(onFailure: ((Error) -> Void)? = nil) async {
        let outcome = await removeOpenMessage(.purge, unread: !isSeen)
        guard outcome.failed.contains(ref) else { return }
        reportRefusal(outcome, to: onFailure)
    }
}
