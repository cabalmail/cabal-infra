import SwiftUI
import CabalmailKit

// "Move to folder" surface for the detail view: the picker sheet and the
// action that runs the move. Lifted into a sibling extension so
// `MessageDetailView` stays under SwiftLint's body-length cap (the struct's
// stored properties are kept internal precisely so these same-module
// extensions can reach them). `move(...)` goes through the mail store's
// mutation service, which shields the move from a concurrent refresh and
// drops the row from every list at once, so this window's selection
// advances exactly as archive/trash does.
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
        // Like dispose, the write drops the row from every list at once and
        // this window's selection advances to the next message.
        await model.move(
            to: destination,
            onFailure: { error in
                appState.showToast(Toast(
                    kind: .error,
                    message: "Couldn't move message: \(error.localizedDescription)"
                ))
            }
        )
    }
}
