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
            // Cmd+Shift+U — Mail.app's mark-unread shortcut. We toggle
            // both ways from the same chord; the icon labels which
            // direction the next press goes.
            .keyboardShortcut("u", modifiers: [.command, .shift])
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
            // Cmd+Shift+L — Mail.app's flag shortcut.
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder
    var remoteContentButton: some View {
        if let model {
            // Always render so the dispose button doesn't shift position
            // when switching between HTML and plain-text messages; dim and
            // disable the control for messages where it has no effect.
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
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.htmlBody == nil)
        }
    }

    @ViewBuilder
    var readerModeButton: some View {
        if let model {
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
            .disabled(model.htmlBody == nil)
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
            // Cmd+Delete — the same chord Mail.app and most macOS list
            // apps bind to "remove from list." Routes through dispose so
            // it follows the user's Archive/Trash preference rather than
            // hard-coding one or the other.
            .keyboardShortcut(.delete, modifiers: .command)
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

    /// Print item shown in the overflow menu. Cmd+P on macOS; the same
    /// shortcut also activates on iPad/iPhone hardware keyboards. Disabled
    /// when the body hasn't loaded yet — printing an empty WKWebView is a
    /// non-action that hides the menu's intent.
    @ViewBuilder
    var printMenuItem: some View {
        if let model {
            Button {
                model.requestPrint()
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(model.htmlBody == nil && model.plainText == nil)
        }
    }

    /// Overflow menu (•••) — houses the actions that don't earn their own
    /// toolbar slot. "Move to folder…" closes the same parity gap with the
    /// React reader; "View source" / "View headers" expose the raw RFC 5322
    /// the reader has already fetched. Cmd+Shift+M and Cmd+U match the
    /// shortcuts on the existing macOS Reply/Forward menu pattern (the
    /// button-level shortcut only fires when this scene is focused, which
    /// matches the existing macOS mail-client convention).
    @ViewBuilder
    var overflowMenuButton: some View {
        Menu {
            if let model {
                Button {
                    moveSheetPresented = true
                } label: {
                    Label("Move to folder…", systemImage: "folder")
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                // Plain text alternative only makes sense when both parts
                // exist; suppress the item otherwise so we don't show a
                // toggle that does nothing.
                if model.htmlBody != nil && model.plainText != nil {
                    Button {
                        model.forcePlainText.toggle()
                    } label: {
                        Label(
                            model.forcePlainText ? "Show HTML" : "Show plain text",
                            systemImage: model.forcePlainText ? "doc.richtext" : "doc.plaintext"
                        )
                    }
                }

                Divider()

                Button {
                    sourceSheetTab = .full
                } label: {
                    Label("View source", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .keyboardShortcut("u", modifiers: .command)

                Button {
                    sourceSheetTab = .headers
                } label: {
                    Label("View headers", systemImage: "list.bullet.rectangle")
                }

                Divider()

                printMenuItem
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions")
        }
    }
}
