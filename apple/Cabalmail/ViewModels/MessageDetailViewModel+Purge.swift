import Foundation
import CabalmailKit

// Permanent deletion out of Trash for the detail pane. Sibling extension
// for the same reason as `+Flags`: keeps the main view-model file under
// SwiftLint's caps. Mirrors `dispose(onSuccess:onFailure:)`'s optimistic
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

    func purge(
        onSuccess: (() -> Void)? = nil,
        onFailure: ((Error) -> Void)? = nil
    ) async {
        // Shield the optimistic prune from a concurrent refresh until the
        // expunge resolves, exactly like the move paths.
        onMoveInFlight?(true)
        defer { onMoveInFlight?(false) }
        onSuccess?()
        do {
            try await client.imapClient.purge(
                folder: folder.path,
                uids: [envelope.uid]
            )
            let uidValidity = try? await currentUIDValidity()
            try? await client.envelopeCache.remove(
                uids: [envelope.uid],
                folder: folder.path
            )
            if let uidValidity {
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: envelope.uid
                )
            }
        } catch {
            errorMessage = "\(error)"
            onFailure?(error)
        }
    }
}
