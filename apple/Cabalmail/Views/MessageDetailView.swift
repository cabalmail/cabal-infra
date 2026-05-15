import SwiftUI
import CabalmailKit

/// Message detail pane — headers block, body renderer, attachment strip.
///
/// Body rendering prefers HTML when both alternatives are present (matches
/// the React app). Remote content is gated off by default per the plan's
/// Phase 4 preference; the toolbar button toggles the reload.
///
/// Layout: the header block and attachment strip sit in a fixed-height
/// region at the top; the body fills the remaining height of the detail
/// column with its own scroll. Previously we wrapped everything in a single
/// outer `ScrollView`, which forced the `WKWebView` onto a fixed `minHeight`
/// (the web view has no intrinsic content size for SwiftUI to grow into),
/// so resizing the window had no effect on the reading area.
struct MessageDetailView: View {
    let folder: Folder
    let envelope: Envelope

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @State private var model: MessageDetailViewModel?
    @State private var composeSeed: Draft?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
                .padding(.horizontal)
                .padding(.top)
            if let attachments = model?.attachments, !attachments.isEmpty {
                AttachmentStrip(attachments: attachments)
                    .padding(.vertical, 8)
            }
            Divider()
            if let model {
                body(for: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(envelope.subject ?? "(no subject)")
        #if os(iOS) || os(visionOS)
        .navigationBarTitleDisplayMode(.inline)
        // Reading a message uses the full bottom edge for the action toolbar;
        // the root `TabView`'s tab bar would otherwise occlude it. The tab
        // bar reappears automatically when the user swipes back to the
        // message list. iPad in regular width and visionOS render the tab
        // chooser as a sidebar instead, so this is a no-op there.
        .toolbar(.hidden, for: .tabBar)
        #endif
        .toolbar { toolbarContent }
        .sheet(item: $composeSeed) { seed in
            composeSheet(for: seed)
        }
        .task {
            // Construct the model on first appear, then either load (initial
            // entry) or re-load if a prior `.task` cycle was cancelled before
            // the body landed. Without the second branch a cancelled-and-
            // re-fired `.task` would short-circuit on the existing model and
            // strand the user in the no-body state forever.
            let activeModel: MessageDetailViewModel
            if let existing = model {
                activeModel = existing
            } else {
                guard let client = appState.client else { return }
                let newModel = MessageDetailViewModel(
                    folder: folder,
                    envelope: envelope,
                    client: client,
                    preferences: preferences
                )
                // Relay flag changes (\Seen toggles) up to AppState so the
                // list view's `.onChange` handler can flip the row's bold
                // styling and unread dot without waiting for the next
                // IDLE / pull-to-refresh.
                let folderPath = folder.path
                let uid = envelope.uid
                newModel.onFlagChanged = { [weak appState] flag, added in
                    appState?.signalFlagChange(
                        folderPath: folderPath,
                        uid: uid,
                        flag: flag,
                        added: added
                    )
                }
                model = newModel
                activeModel = newModel
            }
            if activeModel.htmlBody == nil,
               activeModel.plainText == nil,
               !activeModel.isLoading {
                await activeModel.load()
            }
        }
        .onDisappear { model?.onDisappear() }
    }

    @ViewBuilder
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
            .environment(preferences)
        }
    }

    /// Opens compose pre-populated for a `reply` / `replyAll` / `forward`.
    /// Pulls the user's address list so `ReplyBuilder` can pick a default
    /// From by matching the original message's recipients against owned
    /// addresses (per the React app's 0.3.0 behavior).
    private func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
        guard let client = appState.client else { return }
        Task { @MainActor in
            let addresses = (try? await client.addresses()) ?? []
            let seed = ReplyBuilder.build(
                from: envelope,
                body: model?.plainText,
                mode: mode,
                userAddresses: addresses
            )
            presentCompose(seed: seed)
        }
    }

    /// macOS / iPadOS / visionOS open compose in its own scene; iPhone
    /// keeps the sheet so the message stays on-screen behind it.
    private func presentCompose(seed: Draft) {
        if composeOpensInWindow {
            openWindow(id: composeWindowID, value: seed)
        } else {
            composeSeed = seed
        }
    }

    @ViewBuilder
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let from = envelope.from.first {
                Text(from.formatted)
                    .font(.headline)
            }
            if !envelope.to.isEmpty {
                Text("To: \(envelope.to.map(\.formatted).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !envelope.cc.isEmpty {
                Text("Cc: \(envelope.cc.map(\.formatted).joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let date = envelope.date ?? envelope.internalDate {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func body(for model: MessageDetailViewModel) -> some View {
        // Spinner wins over the error/retry screen whenever a load is in
        // flight, and whenever the view hasn't completed an attempt yet. A
        // fast-failing fetch used to paint the red banner before the user
        // saw any indication of work — issue #403.
        if model.isLoading || !model.hasAttemptedLoad {
            ProgressView("Fetching message…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let html = model.htmlBody {
            // WKWebView manages its own scrolling; fill the available space
            // and let it page through tall messages internally.
            HTMLBodyView(
                html: html,
                inlineImages: model.inlineImages,
                allowRemote: model.remoteContentAllowed,
                readerMode: model.readerMode
            )
        } else if let plain = model.plainText {
            // `.primary` foreground adapts to light/dark mode and gives
            // message text the same contrast as the surrounding chrome.
            ScrollView {
                Text(plain)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button {
                    Task { await model.load() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("No renderable body.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    // The detail view exposes six action buttons. On macOS they live in the
    // top toolbar; on iOS/visionOS they would crowd the inline title and hide
    // the subject, so we route them to a bottom bar where they're also easier
    // to reach with a thumb.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        #if os(iOS) || os(visionOS)
        ToolbarItemGroup(placement: .bottomBar) {
            replyButton
            Spacer()
            seenButton
            Spacer()
            flagButton
            Spacer()
            remoteContentButton
            Spacer()
            readerModeButton
            Spacer()
            disposeButton
        }
        #else
        ToolbarItem { replyButton }
        ToolbarItem { seenButton }
        ToolbarItem { flagButton }
        ToolbarItem { remoteContentButton }
        ToolbarItem { readerModeButton }
        ToolbarItem { disposeButton }
        #endif
    }

}

// Toolbar-button builders and dispose helpers split into an extension so the
// primary view body stays under SwiftLint's 250-line cap.
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
