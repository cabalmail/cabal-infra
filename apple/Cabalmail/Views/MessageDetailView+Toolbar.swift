import SwiftUI
import CabalmailKit

// Toolbar-button builders and dispose helpers for `MessageDetailView`. Lifted
// out of `MessageDetailView.swift` so that file stays under SwiftLint's
// 400-line file_length cap; the buttons all read state off the view's
// `model` and route their actions back through it.

extension MessageDetailView {
    /// Draws whichever button `ReaderToolbarLayout` put in this bottom-bar
    /// slot, so the bar's contents and the tested layout can't drift apart.
    @ViewBuilder
    func bottomBarButton(for action: ReaderToolbarAction) -> some View {
        switch action {
        case .editDraft:     editDraftButton
        case .reply:         replyButton
        case .toggleRead:    seenButton
        case .toggleFlag:    flagButton
        case .remoteContent: remoteContentButton
        case .readerMode:    readerModeButton
        case .dispose:       disposeButton
        case .overflow:      overflowMenuButton
        }
    }

    /// Drafts-folder affordance: resume the open draft in compose.
    /// Disabled until the body fetch + MIME parse complete so a tap can't
    /// seed an empty compose over a draft that hasn't loaded yet.
    @ViewBuilder
    var editDraftButton: some View {
        if let model {
            Button {
                beginResumeDraft()
            } label: {
                Image(systemName: "square.and.pencil")
                    .accessibilityLabel("Edit Draft")
            }
            .disabled(!model.canResumeDraft)
            .accessibilityIdentifier("reader.editDraft")
        }
    }

    @ViewBuilder
    var replyButton: some View {
        // Keyboard shortcuts for Reply / Reply All / Forward live on the
        // macOS menu bar (CabalmailCommands.Message) rather than on these
        // Menu Buttons. A `.keyboardShortcut` on a Button inside a Menu
        // only fires while the detail scene holds AppKit first-responder
        // focus, which it loses the moment a compose window opens — so
        // the second Cmd+R after replying was silently swallowed until
        // the user clicked back into the detail pane.
        Menu {
            Button {
                beginCompose(.reply)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            Button {
                beginCompose(.replyAll)
            } label: {
                Label("Reply All", systemImage: "arrowshape.turn.up.left.2")
            }
            Button {
                beginCompose(.forward)
            } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.forward")
            }
        } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .accessibilityLabel("Reply")
        }
        .accessibilityIdentifier("reader.reply")
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
            .accessibilityIdentifier("reader.toggleRead")
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
            .accessibilityIdentifier("reader.toggleFlag")
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
            .accessibilityIdentifier("reader.remoteContent")
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
            .accessibilityIdentifier("reader.readerMode")
        }
    }

    @ViewBuilder
    var disposeButton: some View {
        if let model {
            let intent = model.disposeIntent
            Button(role: intent.isDestructive ? .destructive : nil) {
                switch intent {
                case .purge:
                    // In Trash, delete means gone forever — confirm first.
                    purgeConfirmPresented = true
                case .restore:
                    Task { await performMove(to: FolderTree.inboxPath) }
                case .move(let action):
                    Task { await performDispose(model: model, action: action) }
                }
            } label: {
                disposeToolbarLabel(for: intent)
            }
            // Cmd+Delete — the same chord Mail.app and most macOS list
            // apps bind to "remove from list." Routes through dispose so
            // it follows the user's Archive/Trash preference rather than
            // hard-coding one or the other. In Trash the chord stages the
            // delete-forever confirmation instead of acting directly.
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("reader.dispose")
        }
    }

    /// Overflow-menu item for whichever dispose destination the toolbar
    /// button does NOT cover: preference says Archive, the menu offers
    /// Delete, and vice versa — both destinations stay one click away
    /// without a second toolbar slot. Inside Trash the toolbar button is
    /// Delete Forever and "move to Trash" is meaningless, so the
    /// alternate is always Archive (the rescue path); inside Archive that
    /// same archive alternate becomes Restore.
    @ViewBuilder
    func alternateDisposeMenuItem(model: MessageDetailViewModel) -> some View {
        let alternate: DisposeIntent = model.isTrashFolder || model.disposeAction == .trash
            ? model.archiveIntent
            : .move(.trash)
        Button(role: alternate.isDestructive ? .destructive : nil) {
            switch alternate {
            case .restore:
                Task { await performMove(to: FolderTree.inboxPath) }
            case .move(let action):
                Task { await performDispose(model: model, action: action) }
            case .purge:
                // `archiveIntent` never resolves to purge; the toolbar
                // button owns the Trash-folder delete-forever path.
                break
            }
        } label: {
            disposeMenuLabel(for: alternate)
        }
    }

    /// Shared dispose flow behind the toolbar button (preference default)
    /// and the overflow menu's alternate-destination item.
    func performDispose(model: MessageDetailViewModel, action: DisposeAction) async {
        await model.dispose(
            action: action,
            onSuccess: {
                // Fires before the server round trip so the list selection
                // advances and the row vanishes instantly.
                appState.signalDisposed(
                    folderPath: folder.path,
                    uid: envelope.uid
                )
            },
            onFailure: { error in
                // The optimistic prune has already happened upstream;
                // surface a toast so the user knows the move didn't take
                // and can retry on the next refresh.
                appState.showToast(Toast(
                    kind: .error,
                    message: failureMessage(for: action, error: error)
                ))
            }
        )
    }

    /// Confirmed permanent delete. Shares the dispose button's optimistic
    /// signal / failure-toast plumbing, but the wire call expunges instead
    /// of moving.
    func runPurge() {
        guard let model else { return }
        Task {
            await model.purge(
                onSuccess: {
                    appState.signalDisposed(
                        folderPath: folder.path,
                        uid: envelope.uid
                    )
                },
                onFailure: { error in
                    appState.showToast(Toast(
                        kind: .error,
                        message: "Couldn't delete message: \(error.localizedDescription)"
                    ))
                }
            )
        }
    }

    /// Bottom-bar label for the dispose button. Icon-only, like every other
    /// bar slot; the accessibility label carries the verb.
    @ViewBuilder
    func disposeToolbarLabel(for intent: DisposeIntent) -> some View {
        Image(systemName: disposeSymbol(for: intent))
            .accessibilityLabel(disposeVerb(for: intent))
    }

    /// Menu twin of `disposeToolbarLabel` — a menu row carrying only an SF
    /// Symbol reads as blank, so the overflow spells the verb out.
    @ViewBuilder
    func disposeMenuLabel(for intent: DisposeIntent) -> some View {
        Label(disposeVerb(for: intent), systemImage: disposeSymbol(for: intent))
    }

    func disposeSymbol(for intent: DisposeIntent) -> String {
        switch intent {
        case .move(.archive): return "archivebox"
        case .move(.trash):   return "trash"
        case .restore:        return "tray.and.arrow.up"
        case .purge:          return "trash.slash"
        }
    }

    func disposeVerb(for intent: DisposeIntent) -> String {
        switch intent {
        case .move(.archive): return "Archive"
        case .move(.trash):   return "Delete"
        case .restore:        return "Restore"
        case .purge:          return "Delete Forever"
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

    #if os(iOS) || os(visionOS)
    /// Menu twins of the two display toggles the bottom bar gave up to stay
    /// inside `ReaderToolbarLayout.capacity`. Same actions, same shortcuts,
    /// spelled out as labelled rows — a menu row carrying only an SF Symbol
    /// reads as blank. macOS keeps both as top-toolbar buttons.
    @ViewBuilder
    var readerModeMenuItem: some View {
        if let model {
            Button {
                model.toggleReaderMode()
            } label: {
                Label(
                    model.readerMode ? "Show original formatting" : "Show reader view",
                    systemImage: model.readerMode ? "text.alignleft" : "doc.richtext"
                )
            }
            .disabled(model.htmlBody == nil)
            .accessibilityIdentifier("reader.readerMode")
        }
    }

    @ViewBuilder
    var remoteContentMenuItem: some View {
        if let model {
            Button {
                model.toggleRemoteContent()
            } label: {
                Label(
                    model.remoteContentAllowed ? "Hide remote content" : "Show remote content",
                    systemImage: model.remoteContentAllowed ? "eye.fill" : "eye.slash"
                )
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(model.htmlBody == nil)
            .accessibilityIdentifier("reader.remoteContent")
        }
    }
    #endif

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
    /// React reader; the alternate dispose item covers whichever of
    /// Archive / Delete the toolbar button doesn't; "View source" /
    /// "View headers" expose the raw RFC 5322 the reader has already
    /// fetched. Cmd+Shift+M and Cmd+U match the shortcuts on the existing
    /// macOS Reply/Forward menu pattern (the button-level shortcut only
    /// fires when this scene is focused, which matches the existing macOS
    /// mail-client convention).
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

                alternateDisposeMenuItem(model: model)

                #if os(iOS) || os(visionOS)
                Divider()

                readerModeMenuItem
                remoteContentMenuItem
                #endif

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
        .accessibilityIdentifier("reader.overflow")
    }
}
