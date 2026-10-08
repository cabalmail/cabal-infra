import SwiftUI
import CabalmailKit

// "Move to folder" surface for the detail view: the picker sheet and the
// action that runs the move. Lifted into a sibling extension so
// `MessageDetailView` stays under SwiftLint's body-length cap (the struct's
// stored properties are kept internal precisely so these same-module
// extensions can reach them). `move(...)` brackets the server round trip with
// `onMoveInFlight` so the list shields the optimistically-pruned row from a
// concurrent refresh; on success it posts `.removed` so the list prunes the
// row and advances selection exactly as archive/trash does.
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
        let movedRef = messageRef
        await model.move(
            to: destination,
            onSuccess: {
                // Match dispose's event so every list prunes the row and this
                // window's selection advances to the next unread message —
                // same optimistic UX, just posted as `.removed` since the row
                // is gone from the source folder either way.
                appState.mailStore.events.post(.removed([movedRef]), from: commandWindowID)
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
