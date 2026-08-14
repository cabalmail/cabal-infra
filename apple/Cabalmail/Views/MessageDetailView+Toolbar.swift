import SwiftUI
import CabalmailKit

// Toolbar-button builders and dispose helpers for `MessageDetailView`. Lifted
// out of `MessageDetailView.swift` so that file stays under SwiftLint's
// 400-line file_length cap; the buttons all read state off the view's
// `model` and route their actions back through it.

extension MessageDetailView {
    /// Draws whichever button `ReaderToolbarLayout` put in this slot — the
    /// touch bottom bar or the macOS top toolbar — so the bars' contents and
    /// the tested layout can't drift apart. Exhaustive one-case-per-action
    /// dispatch; the branch count IS the point, not incidental complexity.
    @ViewBuilder
    // swiftlint:disable:next cyclomatic_complexity
    func toolbarButton(for action: ReaderToolbarAction) -> some View {
        switch action {
        case .editDraft:     editDraftButton
        case .reply:         replyButton
        case .toggleRead:    seenButton
        case .toggleFlag:    flagButton
        case .remoteContent: remoteContentButton
        case .readerMode:    readerModeButton
        case .dispose:       disposeButton
        case .overflow:      overflowMenuButton
        case .move:          moveButton
        case .plainText:     plainTextButton
        case .viewSource:    viewSourceButton
        case .viewHeaders:   viewHeadersButton
        case .printMessage:  printButton
        }
    }

    #if os(iOS)
    /// The action set the pane-scoped bar currently draws, sized to the
    /// measured pane width. Shared by `readerActionBar` and the overflow
    /// menu (which carries the display toggles only while the bar doesn't),
    /// so the two can't disagree about where a toggle lives.
    var ownBarActions: [ReaderToolbarAction] {
        ReaderToolbarLayout.ownBar(
            leading: model?.leadingToolbarAction ?? .reply,
            paneWidth: readerPaneWidth
        )
    }
    #endif

    /// True while the display toggles are drawn on the pane-scoped bar, in
    /// which case the overflow menu must not offer a second copy — two views
    /// would otherwise share one accessibility identifier.
    var displayTogglesAreOnBar: Bool {
        #if os(iOS)
        drawsOwnActionBar && ownBarActions.contains(.readerMode)
        #else
        false
        #endif
    }

    #if os(iOS)
    /// The reader's action set drawn as a bar under the reading pane, for the
    /// layouts where a `.bottomBar` toolbar group would span the whole window
    /// instead (iOS 27 at regular width — see `ReaderToolbarLayout`). Sourced
    /// from `ReaderToolbarLayout.ownBar`, which sizes the item set to the
    /// bar's measured width — the pane is user-resizable on iPad, and unlike
    /// the system bar this one never compacts, so wide panes carry the full
    /// seven actions. The bar fills the pane regardless of item count (the
    /// spacers are greedy), so the measurement can't feed back into itself.
    /// Chrome follows the message list's bulk action bar (`Divider` over a
    /// `.bar` background), which ties the controls to the pane they act on —
    /// the thing the window-spanning bar loses.
    @ViewBuilder
    var readerActionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(ownBarActions.enumerated()), id: \.element) { index, action in
                    if index > 0 { Spacer(minLength: 0) }
                    toolbarButton(for: action)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)
            // The faces are `Label`s for the macOS » popup's sake; this is a
            // plain `HStack`, not a toolbar, so icon-only must be stated. The
            // style doesn't leak into the controls' hold menus — UIKit menu
            // rows always draw title + icon.
            .labelStyle(.iconOnly)
        }
        .onGeometryChange(for: CGFloat.self) { barProxy in
            barProxy.size.width
        } action: { newWidth in
            readerPaneWidth = newWidth
        }
    }
    #endif

    // Every button face here is a `Label`, not a bare `Image`: on macOS the
    // system's "more toolbar items" (») popup flattens evicted buttons into
    // menu rows and draws the item's title, so an icon-only face renders as a
    // blank row there (#1047). The toolbars themselves still draw icons only —
    // macOS's unified toolbar does that by default, and the touch call sites
    // apply `.labelStyle(.iconOnly)` (see `readerActionBar` and the
    // `.bottomBar` group in `MessageDetailView.toolbarContent`).

    /// Drafts-folder affordance: resume the open draft in compose.
    /// Disabled until the body fetch + MIME parse complete so a tap can't
    /// seed an empty compose over a draft that hasn't loaded yet.
    @ViewBuilder
    var editDraftButton: some View {
        if let model {
            Button {
                beginResumeDraft()
            } label: {
                Label("Edit Draft", systemImage: "square.and.pencil")
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
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .accessibilityIdentifier("reader.reply")
    }

    // `seenButton` lives in `MessageDetailView+SeenOptions.swift` with the
    // macOS split-control menu it grew — the same arrangement as
    // `disposeButton` below.

    @ViewBuilder
    var flagButton: some View {
        if let model {
            Button {
                Task { await model.toggleFlagged() }
            } label: {
                Label(
                    model.isFlagged ? "Unflag" : "Flag",
                    systemImage: model.isFlagged ? "flag.slash" : "flag"
                )
            }
            // Cmd+Shift+L rides `readerChordHosts`, not this button — an
            // equivalent on a toolbar item dies with the item when the
            // toolbar overflows (#1047).
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
                Label(
                    model.remoteContentAllowed
                        ? "Hide remote content"
                        : "Show remote content",
                    systemImage: model.remoteContentAllowed ? "eye.fill" : "eye.slash"
                )
            }
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
                Label(
                    model.readerMode
                        ? "Show original formatting"
                        : "Show reader view",
                    systemImage: model.readerMode ? "text.alignleft" : "doc.richtext"
                )
            }
            .disabled(model.htmlBody == nil)
            .accessibilityIdentifier("reader.readerMode")
        }
    }

    // `disposeButton` lives in `MessageDetailView+DisposeOptions.swift`
    // with the macOS split-control menu it grew — keeping it here would
    // push this file past SwiftLint's file_length cap.

    // The overflow menu used to carry an "alternate dispose" item (Delete
    // for users whose button says Archive, and vice versa). It's gone: the
    // dispose control's own option menu offers every Archive/Delete pair,
    // so the alternate was a second copy of a reachable action (#1047).

    /// Shared dispose flow behind the dispose control's primary action and
    /// its option-menu rows.
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

    /// Face of the dispose control: verb + symbol for the destination in
    /// effect. The bars draw it icon-only like every other slot; the title
    /// is what the macOS » popup shows when the toolbar overflows.
    @ViewBuilder
    func disposeToolbarLabel(for intent: DisposeIntent) -> some View {
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
    /// reads as blank. Shown only while the toggles are off the bar: a wide
    /// pane-scoped bar promotes them back (`displayTogglesAreOnBar`), and the
    /// menu must not carry a second copy. macOS keeps both as top-toolbar
    /// buttons.
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
            .disabled(model.htmlBody == nil)
            .accessibilityIdentifier("reader.remoteContent")
        }
    }
    #endif

    /// Print item shown in the touch platforms' overflow menu (macOS draws a
    /// toolbar button instead — see `printButton`). Cmd+P rides
    /// `readerChordHosts`. Disabled when the body hasn't loaded yet —
    /// printing an empty WKWebView is a non-action that hides the menu's
    /// intent.
    @ViewBuilder
    var printMenuItem: some View {
        if let model {
            Button {
                model.requestPrint()
            } label: {
                Label("Print…", systemImage: "printer")
            }
            .disabled(model.htmlBody == nil && model.plainText == nil)
        }
    }

    /// Overflow menu (•••) — the touch platforms' home for the actions that
    /// don't earn a slot on their width-budgeted bars. macOS stopped using it
    /// in the #1047 rework: there every action is its own toolbar button and
    /// the system's » popup is the constrained-space fallback. "Move to
    /// folder…" closes the same parity gap with the React reader; "View
    /// source" / "View headers" expose the raw RFC 5322 the reader has
    /// already fetched. Hardware-keyboard chords for these actions ride
    /// `readerChordHosts`, not the rows.
    @ViewBuilder
    var overflowMenuButton: some View {
        Menu {
            if let model {
                Button {
                    moveSheetPresented = true
                } label: {
                    Label("Move to folder…", systemImage: "folder")
                }

                #if os(iOS) || os(visionOS)
                if !displayTogglesAreOnBar {
                    Divider()

                    readerModeMenuItem
                    remoteContentMenuItem
                }
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

                Button {
                    sourceSheetTab = .headers
                } label: {
                    Label("View headers", systemImage: "list.bullet.rectangle")
                }

                Divider()

                printMenuItem
            }
        } label: {
            Label("More actions", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("reader.overflow")
    }
}
