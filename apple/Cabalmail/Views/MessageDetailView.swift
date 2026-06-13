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

    // Properties reached by sibling extensions in `+Toolbar` and `+Compose`
    // are kept at internal (default) access. `private` in this struct
    // would block access from those files even though they're in the same
    // module; the same-module / different-file extension pattern is the
    // accepted way to keep this struct under SwiftLint's body-length cap.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) var preferences
    @Environment(\.openWindow) var openWindow
    @State var model: MessageDetailViewModel?
    @State var composeSeed: Draft?
    @State var moveSheetPresented = false
    @State var sourceSheetTab: MessageSourceSheet.Tab?
    @State var senderContactName: String?
    /// Presents the "Delete Forever?" confirmation when the delete button
    /// fires while the message lives in Trash. Non-private so the
    /// `+Toolbar` extension's dispose button can stage it.
    @State var purgeConfirmPresented = false

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
        .confirmationDialog(
            "Delete Forever?",
            isPresented: $purgeConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) {
                runPurge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This message will be permanently deleted. This can't be undone.")
        }
        .onChange(of: appState.replyRequestTick) { _, _ in beginCompose(.reply) }
        .onChange(of: appState.replyAllRequestTick) { _, _ in beginCompose(.replyAll) }
        .onChange(of: appState.forwardRequestTick) { _, _ in beginCompose(.forward) }
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
                // Bracket each flag write so the list shields the optimistic
                // flag from a refresh that lands before the write resolves
                // (the cross-view analogue of the list's own pending-flag
                // shield). Folder-keyed so a UID collision across mailboxes
                // can't mis-shield an unrelated row.
                newModel.onFlagWriteInFlight = { [weak appState] inFlight in
                    appState?.setFlagWrite(
                        folderPath: folderPath,
                        uid: uid,
                        inFlight: inFlight
                    )
                }
                // Likewise bracket archive / trash / move so the list keeps
                // the optimistically-pruned row gone until the move resolves,
                // rather than letting a mid-move refresh resurrect it.
                newModel.onMoveInFlight = { [weak appState] inFlight in
                    appState?.setMoveInFlight(
                        folderPath: folderPath,
                        uid: uid,
                        inFlight: inFlight
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
    private func sourceSheet(initialTab: MessageSourceSheet.Tab) -> some View {
        if let model {
            MessageSourceSheet(
                model: model,
                initialTab: initialTab,
                onClose: { sourceSheetTab = nil }
            )
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
                    Text(headerFromLabel(for: from))
                        .font(.headline)
                        .task(id: "\(from.mailbox.lowercased())@\(from.host.lowercased())") {
                            await hydrateSenderContactName(for: from)
                        }
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

    /// "Name <addr@host>" formatter that prefers the envelope's RFC 5322
    /// phrase first, then the user's own name from Contacts. Mirrors
    /// `EmailAddress.formatted` but with the contacts fallback wedged
    /// in between.
    private func headerFromLabel(for address: EmailAddress) -> String {
        let addrPart = "\(address.mailbox)@\(address.host)"
        if let name = address.displayName, !name.isEmpty {
            return "\(name) <\(addrPart)>"
        }
        if let name = senderContactName, !name.isEmpty {
            return "\(name) <\(addrPart)>"
        }
        return addrPart
    }

    private func hydrateSenderContactName(for address: EmailAddress) async {
        senderContactName = nil
        if let name = address.displayName, !name.isEmpty { return }
        senderContactName = await appState.contactsStore.displayName(for: address)
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
            if model?.isDraftsFolder == true {
                editDraftButton
                Spacer()
            }
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
        if model?.isDraftsFolder == true {
            ToolbarItem { editDraftButton }
        }
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
