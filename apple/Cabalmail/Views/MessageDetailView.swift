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

    // `appState` and `model` are reached by the toolbar extension in
    // `MessageDetailView+Toolbar.swift`; SwiftUI's `private` in this struct
    // would block access from that file. Kept `internal` (default) and not
    // exposed beyond the module.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    @State var model: MessageDetailViewModel?
    @State private var composeSeed: Draft?
    @State var moveSheetPresented = false
    @State var sourceSheetTab: MessageSourceSheet.Tab?

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
        .sheet(isPresented: $moveSheetPresented) {
            moveSheet
        }
        .sheet(item: $sourceSheetTab) { tab in
            sourceSheet(initialTab: tab)
        }
        .onAppear {
            BodyFetchLog.appear(uid: envelope.uid, modelExists: model != nil)
            // Drive the body fetch from `.onAppear` rather than SwiftUI's
            // `.task` modifier. On iPhone-compact NavigationStack push,
            // `.task` fires twice for the same view identity with
            // unpredictable cancellation timing — the live instance can
            // race the doomed one, or both can be cancelled at entry,
            // leaving the view stuck on a spinner. `.onAppear` only fires
            // when the view actually appears, and the load itself runs on
            // an unstructured Task owned by the view model, immune to
            // SwiftUI's `.task` cancellation. The model cancels that Task
            // in `onDisappear()` when the view is genuinely going away.
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
            activeModel.startLoadIfNeeded()
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

    @ViewBuilder
    private var moveSheet: some View {
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

    @ViewBuilder
    private func sourceSheet(initialTab: MessageSourceSheet.Tab) -> some View {
        if let model {
            MessageSourceSheet(
                model: model,
                initialTab: initialTab,
                onClose: { sourceSheetTab = nil }
            )
        }
    }

    private func performMove(to destination: String) async {
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

    /// Opens compose pre-populated for a `reply` / `replyAll` / `forward`.
    /// Pulls the user's address list so `ReplyBuilder` can pick a default
    /// From by matching the original message's recipients against owned
    /// addresses (per the React app's 0.3.0 behavior).
    func beginCompose(_ mode: ReplyBuilder.ReplyMode) {
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
        HStack(alignment: .top, spacing: 12) {
            if let apiClient = appState.client?.apiClient {
                AvatarView(sender: envelope.from.first, apiClient: apiClient)
            }
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
            Spacer(minLength: 0)
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
        } else if let html = model.htmlBody, !model.forcePlainText {
            // WKWebView manages its own scrolling; fill the available space
            // and let it page through tall messages internally.
            HTMLBodyView(
                html: html,
                inlineImages: model.inlineImages,
                allowRemote: model.remoteContentAllowed,
                readerMode: model.readerMode,
                printRequestTick: model.printRequestTick
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
            Spacer()
            overflowMenuButton
        }
        #else
        ToolbarItem { replyButton }
        ToolbarItem { seenButton }
        ToolbarItem { flagButton }
        ToolbarItem { remoteContentButton }
        ToolbarItem { readerModeButton }
        ToolbarItem { disposeButton }
        ToolbarItem { overflowMenuButton }
        #endif
    }

}

// Toolbar-button builders and dispose helpers live in
// `MessageDetailView+Toolbar.swift` so this file stays under SwiftLint's
// 400-line file_length cap.
