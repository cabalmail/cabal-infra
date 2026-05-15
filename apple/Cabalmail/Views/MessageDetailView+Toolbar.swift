import SwiftUI
import CabalmailKit

// Toolbar-button builders and dispose helpers for `MessageDetailView`. Lifted
// out of `MessageDetailView.swift` so that file stays under SwiftLint's
// 400-line file_length cap; the buttons all read state off the view's
// `model` and route their actions back through it.

extension MessageDetailView {
    @ViewBuilder
    var replyButton: some View {
        Menu {
            Button {
                beginCompose(.reply)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .keyboardShortcut("r", modifiers: .command)
            Button {
                beginCompose(.replyAll)
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            Button {
                beginCompose(.forward)
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.forward")
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .accessibilityLabel("Reply")
        }
    }

    @ViewBuilder
    var seenButton: some View {
        if let model {
            Button {
                Task { await model.toggleSeen() }
            } label: {
                // Icon reflects the current state; tap-action is the
                // inverse. Matches Mail.app: an already-read message
                // shows "envelope.open" and tapping marks it unread.
                Image(systemName: model.isSeen ? "envelope.open" : "envelope.badge")
                    .accessibilityLabel(model.isSeen ? "Mark as unread" : "Mark as read")
            }
        }
    }

    @ViewBuilder
    var flagButton: some View {
        if let model {
            Button {
                Task { await model.toggleFlagged() }
            } label: {
                Image(systemName: model.isFlagged ? "flag.slash" : "flag")
                    .accessibilityLabel(model.isFlagged ? "Unflag" : "Flag")
            }
        }
    }

    @ViewBuilder
    var remoteContentButton: some View {
        if let model, model.htmlBody != nil {
            Button {
                model.toggleRemoteContent()
            } label: {
                Image(systemName: model.remoteContentAllowed
                      ? "eye.fill"
                      : "eye.slash")
                    .accessibilityLabel(
                        model.remoteContentAllowed
                        ? "Hide remote content"
                        : "Show remote content"
                    )
            }
        }
    }

    @ViewBuilder
    var readerModeButton: some View {
        if let model, model.htmlBody != nil {
            Button {
                model.toggleReaderMode()
            } label: {
                Image(systemName: model.readerMode
                      ? "text.alignleft"
                      : "doc.richtext")
                    .accessibilityLabel(
                        model.readerMode
                        ? "Show original formatting"
                        : "Show reader view"
                    )
            }
        }
    }

    @ViewBuilder
    var disposeButton: some View {
        if let model {
            Button(role: disposeRole(for: model.disposeAction)) {
                Task {
                    await model.dispose(
                        onSuccess: {
                            // Fires before the server round trip so the
                            // list selection advances and the row vanishes
                            // instantly.
                            appState.signalDisposed(
                                folderPath: folder.path,
                                uid: envelope.uid
                            )
                        },
                        onFailure: { error in
                            // The optimistic prune has already happened
                            // upstream; surface a toast so the user knows
                            // the move didn't take and can retry on the
                            // next refresh.
                            appState.showToast(Toast(
                                kind: .error,
                                message: failureMessage(for: model.disposeAction, error: error)
                            ))
                        }
                    )
                }
            } label: {
                disposeToolbarLabel(for: model.disposeAction)
            }
        }
    }

    @ViewBuilder
    func disposeToolbarLabel(for action: DisposeAction) -> some View {
        switch action {
        case .archive:
            Image(systemName: "archivebox")
                .accessibilityLabel("Archive")
        case .trash:
            Image(systemName: "trash")
                .accessibilityLabel("Delete")
        }
    }

    func disposeRole(for action: DisposeAction) -> ButtonRole? {
        switch action {
        case .archive: return nil
        case .trash:   return .destructive
        }
    }

    func failureMessage(for action: DisposeAction, error: Error) -> String {
        let verb: String
        switch action {
        case .archive: verb = "archive"
        case .trash:   verb = "delete"
        }
        return "Couldn't \(verb) message: \(error.localizedDescription)"
    }
}
