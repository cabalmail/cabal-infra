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
