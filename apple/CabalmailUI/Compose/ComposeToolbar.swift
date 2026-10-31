import SwiftUI

/// Compose's bar buttons, placed by `ComposeLaptopPolicy.BarHost`.
///
/// Everywhere but laptop pose they are today's: Cancel, Attach, Open in New
/// Window where it is offered, and Send, in the navigation bar. In laptop
/// pose at rest every button sits in a bar at the bottom, below the fold,
/// with Edit Message, which puts the caret back in the body. While the
/// software keyboard is up it fills the space below the fold, so Cancel,
/// Attach and Send go back to the top bar and nothing else does: the decided
/// exception to the rule of no taps above a laptop fold. Each identifier
/// exists once in either placement, and the buttons hold no state, so
/// moving them between bars costs nothing.
struct ComposeToolbar<AttachMenu: View>: ToolbarContent {
    let model: ComposeViewModel
    let host: ComposeLaptopPolicy.BarHost
    let cancel: () async -> Void
    let send: () async -> Void
    let editMessage: () -> Void
    @ViewBuilder let attachMenu: () -> AttachMenu

    /// Whether the window's bars are a side strip, where Cancel and Send
    /// carry symbols (`ComposeBarLabel`).
    @Environment(\.barsAreVertical) private var barsAreVertical

    var body: some ToolbarContent {
        if host.drawsBottomGroup {
            ToolbarItemGroup(placement: .bottomEdge) {
                cancelButton
                Spacer()
                attachMenu().menuOrderFromBottomBar(true)
                Spacer()
                editMessageButton
                Spacer()
                ComposeWindowOfferButton(model: model)
                Spacer()
                sendButton
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                cancelButton
            }
            .keepsInBar()
            ToolbarItem {
                attachMenu()
            }
            if host.offersWindowInTopBar {
                ComposeWindowOfferItem(model: model)
            }
            ToolbarItem(placement: .confirmationAction) {
                sendButton
            }
            .keepsInBarFirst()
        }
    }

    private var cancelButton: some View {
        Button {
            Task { await cancel() }
        } label: {
            ComposeBarLabel.cancel(barsAreVertical: barsAreVertical).label("Cancel", systemImage: "xmark")
        }
        .accessibilityIdentifier("compose.cancel")
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            ComposeBarLabel.send(barsAreVertical: barsAreVertical, isSending: model.isSending)
                .label("Send", systemImage: "paperplane")
        }
        .symbolEffect(.pulse, isActive: model.isSending)
        .disabled(!model.canSend || model.isSending)
        .accessibilityIdentifier("compose.send")
    }

    private var editMessageButton: some View {
        Button(action: editMessage) {
            Label("Edit Message", systemImage: "character.cursor.ibeam")
        }
        .disabled(!ComposeLaptopPolicy.mayEditMessage(
            hasStarted: model.hasStarted,
            holdsDraft: model.holdsDraft,
            isSending: model.isSending,
            isMarkdown: model.editorMode == .markdown,
            editorDown: model.editorUnavailable != nil
        ))
        .accessibilityIdentifier("compose.editMessage")
    }
}
