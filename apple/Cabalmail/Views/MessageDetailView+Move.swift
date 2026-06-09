import SwiftUI
import CabalmailKit

// "Move to folder" surface for the detail view: the picker sheet and the
// action that runs the move. Lifted into a sibling extension so
// `MessageDetailView` stays under SwiftLint's body-length cap (the struct's
// stored properties are kept internal precisely so these same-module
// extensions can reach them). `move(...)` brackets the server round trip with
// `onMoveInFlight` so the list shields the optimistically-pruned row from a
// concurrent refresh; on success it posts `signalDisposed` so the list prunes
// the row and advances selection exactly as archive/trash does.
extension MessageDetailView {
    @ViewBuilder
    var moveSheet: some View {
        if let client = appState.client {
            MoveToFolderSheet(
                currentFolder: folder,
                client: client,
                onSelect: { destination in
                    moveSheetPresented = false
                    Task { await performMove(to: destination.path) }
                },
                onCancel: { moveSheetPresented = false }
            )
        }
    }

    func performMove(to destination: String) async {
        guard let model else { return }
        let sourceFolderPath = folder.path
        let movedUID = envelope.uid
        await model.move(
            to: destination,
            onSuccess: {
                // Match dispose's signal so MessageListView prunes the row
                // and advances selection to the next unread message — same
                // optimistic UX, just routed through `signalDisposed` since
                // the row is gone from the source folder either way.
                appState.signalDisposed(
                    folderPath: sourceFolderPath,
                    uid: movedUID
                )
            },
            onFailure: { error in
                appState.showToast(Toast(
                    kind: .error,
                    message: "Couldn't move message: \(error.localizedDescription)"
                ))
            }
        )
    }
}
