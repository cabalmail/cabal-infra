import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import PhotosUI
// For the keyboard-frame notification the compose form scrolls on; SwiftUI
// re-exports very little of UIKit.
import UIKit
#endif
import UniformTypeIdentifiers

/// Compose scene. macOS, iPadOS, and visionOS host this in a standalone
/// `WindowGroup` opened via `openWindow` (see `ComposeWindowScene`); iPhone
/// keeps it as a modal sheet so the user doesn't get torn away from the
/// mailbox they were just reading on a single-scene device.
///
/// The form is four labeled fields (From picker, To/Cc/Bcc tokens, subject,
/// dual-mode rich-text + Markdown body) plus an attachment strip and a Send
/// button. iOS / iPadOS / visionOS render the fields as a grouped `Form`;
/// macOS uses a compact Mail-style header grid with the editor filling the
/// remaining window (`ComposeMacHeader` + `macLayout`) because SwiftUI's
/// default macOS form style centers the fields beside a label gutter that
/// wastes roughly half the window. The primary affordance of the From
/// picker is **"Create new address…"** — per `docs/README.md`, minting a
/// fresh subdomain-scoped address per contact is Cabalmail's core idiom, so
/// the picker never silently preselects one and Send stays disabled until
/// the user chooses.
struct ComposeView: View {
    /// SwiftUI focus targets. The body editor is a WKWebView and isn't part
    /// of the SwiftUI focus system; we route body focus through
    /// `RichTextEditorController.focusAtStart()` instead. The three
    /// recipient cases drive the autocomplete-suggestion list, which
    /// renders below whichever recipient field currently holds focus.
    enum Field: Hashable { case to, cc, bcc }

    /// The compose model, built once per compose surface. It arrives as a
    /// factory rather than a value so a view struct SwiftUI is about to
    /// discard never constructs one — see `DeferredComposeModel` (#1102).
    @State private var deferredModel: DeferredComposeModel
    var model: ComposeViewModel { deferredModel.model }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusedField: Field?
    @State private var showNewAddressSheet = false
    @State private var showDiscardConfirm = false
    /// All-contacts snapshot for the suggestion list. Loaded once when
    /// the compose surface appears; the inner filter runs locally on
    /// each keystroke. Stays empty when contacts access isn't granted.
    @State private var recipientCandidates: [RecipientSuggestion] = []
    #if os(iOS) || os(visionOS)
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    #endif
    @State private var showFileImporter = false
    /// Compose-scoped banner. The compose surface is a separate window
    /// (macOS / iPad regular) or a sheet (iPhone), so the root
    /// `AppState.toast` overlay can't reach it — host the post-creation
    /// "Created … / Copy" banner here instead.
    @State private var composeToast: Toast?
    #if os(macOS)
    /// Intercepts the macOS window's red close button (and Cmd+W) so it
    /// routes through the same "Discard draft?" dialog as the toolbar
    /// Cancel button. iOS / visionOS / iPadOS dismiss via the modal sheet
    /// or scene close gesture and don't need this hook.
    @State private var closeCoordinator = ComposeWindowCloseCoordinator()
    #endif

    /// `@autoclosure` on purpose: the call sites read as
    /// `ComposeView(model: ComposeViewModel(…))`, but the model is only
    /// built when SwiftUI keeps the view (#1102).
    init(model: @autoclosure @escaping () -> ComposeViewModel) {
        _deferredModel = State(wrappedValue: DeferredComposeModel(model))
    }

    var body: some View {
        NavigationStack {
            composeContent
            .navigationTitle(model.navigationTitle)
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .task {
                // Pick up forwarded attachments stashed by the forward
                // action. They hand off out-of-band, keyed by seed id,
                // rather than riding the seed itself. Pop-once: a
                // system-restored compose scene finds nothing and simply
                // composes without them.
                let forwarded = appState.consumeComposeAttachments(for: model.draftId)
                if !forwarded.isEmpty {
                    model.seedForwardedAttachments(forwarded)
                }
                await model.start()
                // Snapshot contacts once per compose surface. The list is
                // bounded by the user's address book; the per-keystroke
                // filter runs locally against this in-memory array so
                // typing doesn't take a CNContactStore hit per character.
                recipientCandidates = await appState.contactsStore.allEntries()
                #if os(macOS)
                // Cmd+W and the red close button run exactly what the
                // toolbar Cancel button runs, so all three ask only when
                // there is a draft to decide about (#1106). The close has
                // already been declined by the time this fires, so the
                // await on the WebKit bridge inside costs nothing but a
                // window that stays up a moment longer.
                closeCoordinator.onCloseAttempt = { await cancelOrAsk() }
                #endif
                if model.shouldFocusBodyOnAppear {
                    // Clear the SwiftUI focus binding so the Form can't
                    // keep the To field as its first responder behind the
                    // WKWebView. focusAtStart then promotes the editor to
                    // window first responder on macOS and places the caret
                    // at the start of the body via the JS bridge.
                    focusedField = nil
                    await model.editorController.focusAtStart()
                } else {
                    focusedField = .to
                }
            }
            #if os(macOS)
            .background {
                ComposeWindowCloseInterceptor(coordinator: closeCoordinator)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            #endif
            .onDisappear {
                model.stop()
            }
            .sheet(isPresented: $showNewAddressSheet) {
                NewAddressSheet(
                    domains: appState.client?.configuration.domains ?? [],
                    onCreate: { address in
                        await model.onAddressCreated(address)
                        composeToast = .addressCreated(address)
                    }
                )
                .environment(appState)
            }
            #if os(iOS) || os(visionOS)
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoSelection,
                maxSelectionCount: 5,
                matching: .images
            )
            .onChange(of: photoSelection) { _, items in
                Task { await ingestPhotoItems(items) }
            }
            #endif
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                Task { await ingestFileImport(result) }
            }
            .confirmationDialog(
                "Discard draft?",
                isPresented: $showDiscardConfirm
            ) {
                ForEach(ComposeCancelChoice.allCases, id: \.self) { choice in
                    Button(choice.title, role: choice.role) { perform(choice) }
                }
            } message: {
                Text("Keep a copy of the draft for later, discard it now, or go back to editing.")
            }
            .toastOverlay($composeToast)
        }
    }

    // MARK: - Cancel dialog

    /// Cancel: put up the three-way dialog when there is a draft to decide
    /// about, and otherwise just close.
    ///
    /// The dialog used to go up unconditionally, so closing a composer the
    /// user had not typed in still demanded a Save / Discard / Keep Editing
    /// answer over an empty buffer — every branch of which throws away
    /// nothing (#1094). `ComposeCancelPolicy` owns the rule; the emptiness
    /// it reads is the same `hasDraftContent(bodies:)` that `cancel()`
    /// consults, computed the same way, so the question is asked exactly
    /// when the answer could matter.
    ///
    /// Bodies come from the WebKit bridge, hence the `await`. Every cancel
    /// gesture runs this: the toolbar button, and on macOS the window-close
    /// intercept that Cmd+W and the red close button go through
    /// (`closeCoordinator.onCloseAttempt`). Wiring the intercept here is
    /// what stopped those two asking over an untouched composer (#1106);
    /// they can afford the bridge round trip because `windowShouldClose`
    /// has already declined the close and returned `false`.
    private func cancelOrAsk() async {
        let bodies = await model.computeMessageBodies()
        guard !ComposeCancelPolicy.needsDecision(
            bridgeFailed: model.editorController.bridgeFailure != nil,
            hasContent: model.hasDraftContent(bodies: bodies)
        ) else {
            showDiscardConfirm = true
            return
        }
        #if os(macOS)
        // Closing without the dialog still closes the window; pre-approve
        // so the close intercept doesn't re-ask what we just decided not
        // to ask.
        closeCoordinator.allowsClose = true
        #endif
        // Re-resolves against the same emptiness and takes `.discardEmpty`:
        // drops any server copy the autosave left, removes the local one,
        // closes.
        await model.cancel()
    }

    /// Runs the outcome the user picked in the cancel-compose dialog. Stays
    /// in this file (rather than the `+Subviews` extension) because it
    /// touches the `private` close coordinator.
    private func perform(_ choice: ComposeCancelChoice) {
        switch choice {
        case .discard:
            Task {
                #if os(macOS)
                // Pre-approve the close so the dismissWindow call inside
                // discard() doesn't get re-intercepted by the
                // NSWindowDelegate.
                closeCoordinator.allowsClose = true
                #endif
                await model.discard()
                // The discard expunged the server copy an open Drafts list
                // — and the reader this dismissal returns to — is still
                // holding. Say so, or the row survives and Edit Draft on it
                // reopens the discarded draft with Send live (#1081). Same
                // signal as Save Draft; the replacement has no survivor, so
                // the policy drops the reader rather than re-pointing it.
                if let replacement = model.retiredDraftReplacement {
                    appState.signalDraftReplaced(
                        folderPath: "Drafts",
                        replacement: replacement
                    )
                }
            }
        case .saveDraft:
            Task {
                #if os(macOS)
                closeCoordinator.allowsClose = true
                #endif
                let didClose = await model.cancel()
                // The save replaced the server copy, expunging the UID an
                // open Drafts list — and the reader this dismissal returns
                // to — is still holding. Hand the list the whole chain plus
                // the survivor so it can swap rather than strand the user
                // on content the server no longer has (#1078). An emptied
                // body takes the `.discardEmpty` exit through this same
                // button and reports a chain with no survivor (#1081); a
                // first save reports the survivor with nothing retired, and
                // rides the same refresh into the list (#1083).
                if didClose, let replacement = model.retiredDraftReplacement {
                    appState.signalDraftReplaced(
                        folderPath: "Drafts",
                        replacement: replacement
                    )
                }
                #if os(macOS)
                // IMAP save failed: keep the user in the window so they can
                // see the error banner and retry.
                if !didClose {
                    closeCoordinator.allowsClose = false
                }
                #endif
            }
        case .keepEditing:
            // No-op by design — the dialog dismisses and the composer, with
            // everything typed so far, is still there.
            break
        }
    }

    // MARK: - Subviews

    // `attachmentRow`, `ingestFileImport`, and `mimeType(for:)` live in
    // `ComposeView+Subviews.swift` to keep the struct body under the
    // SwiftLint length ceiling. Anything that touches `@State private`
    // storage stays here because `private` doesn't reach an extension
    // in another file.

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                Task { await cancelOrAsk() }
            }
            .accessibilityIdentifier("compose.cancel")
        }
        ToolbarItem {
            attachMenu
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task {
                    #if os(macOS)
                    // Send dismisses the window on success; pre-approve so
                    // the close-button intercept doesn't pop the dialog
                    // in front of a message the user already committed.
                    closeCoordinator.allowsClose = true
                    #endif
                    let sent = await model.send()
                    #if os(macOS)
                    if !sent { closeCoordinator.allowsClose = false }
                    #endif
                    guard sent else { return }
                    // Sending from a draft discards the server copy, so the
                    // Drafts list is showing a message that no longer
                    // exists. Prune it through the same signal the reader's
                    // archive/move actions use instead of waiting for the
                    // next background reconcile (the folder is unsubscribed
                    // by default, so that took over a minute). "Drafts" is
                    // the mailbox `/save_draft` pins every draft to; see
                    // `MessageDetailViewModel.isDraftsFolder`.
                    // Every UID the session held, not just the last: a 60s
                    // autosave replaces the copy under a new UID and the
                    // open list is still rendering the old one (#1071).
                    appState.signalDisposed(
                        folderPath: "Drafts",
                        uids: model.supersededDraftUIDs
                    )
                    // A reply left the device (or the outbox owns it now):
                    // mark the original `\Answered` so the list's replied
                    // arrow appears without waiting for a refresh.
                    if let folder = model.replySourceFolder, let uid = model.replySourceUid {
                        appState.markAnswered(folderPath: folder, uid: uid)
                    }
                    // Surface the outcome as a toast on the shared AppState
                    // so the user sees confirmation after the sheet dismisses.
                    // `.queued` means the message is in the outbox and
                    // `SendQueue` will drain it on reconnect — callers should
                    // understand their message isn't lost.
                    switch model.lastSendOutcome {
                    case .sent:
                        appState.showToast(.init(kind: .success, message: "Message sent."))
                    case .queued:
                        appState.showToast(.init(
                            kind: .warning,
                            message: "Message queued — will send when back online."
                        ))
                    case .none:
                        break
                    }
                }
            } label: {
                if model.isSending {
                    ProgressView()
                } else {
                    Text("Send")
                }
            }
            .disabled(!model.canSend || model.isSending)
            .accessibilityIdentifier("compose.send")
        }
    }

    @ViewBuilder
    private var attachMenu: some View {
        #if os(iOS) || os(visionOS)
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Add Photo", systemImage: "photo")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("Add File", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .accessibilityLabel("Attach")
        }
        .accessibilityIdentifier("compose.attach")
        #else
        Button {
            showFileImporter = true
        } label: {
            Image(systemName: "paperclip")
                .accessibilityLabel("Attach file")
        }
        .accessibilityIdentifier("compose.attach")
        #endif
    }

    // MARK: - Attachments

    #if os(iOS) || os(visionOS)
    private func ingestPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            // `Data` is the asset's *native* encoding — PNG for a screenshot,
            // HEIC for most camera captures — so the label has to follow the
            // bytes. It used to be the constant pair `.jpg` / `image/jpeg`,
            // which happened to be right only for assets that were already
            // JPEG (#1140).
            let (mime, ext) = photoTypeLabels(for: item, data: data)
            model.addAttachment(
                filename: "photo-\(UUID().uuidString.prefix(8)).\(ext)",
                mimeType: mime,
                data: data
            )
        }
        photoSelection = []
    }

    #endif

    // MARK: - Contacts

    /// Re-snapshot the address book after the user grants Contacts access
    /// from a recipient field's picker button. All three fields share this
    /// one array, so one grant re-arms all of them.
    func reloadRecipientCandidates() {
        Task { @MainActor in
            recipientCandidates = await appState.contactsStore.allEntries()
        }
    }
}

// MARK: - Layout fork

// Same-file extension so these builders can reach the `private`
// focus / sheet / candidate state (file-scoped `private` covers
// extensions of the type in the same file).
extension ComposeView {
    /// Platform fork for the compose surface. iOS / iPadOS / visionOS
    /// keep the grouped `Form`; macOS gets a Mail-style compact layout
    /// because SwiftUI's default macOS form style (`.columns`) centers
    /// the controls beside a label gutter sized at roughly half the
    /// window, leaving the upper-left quadrant empty.
    @ViewBuilder
    private var composeContent: some View {
        #if os(macOS)
        macLayout
        #else
        composeForm
        #endif
    }

    #if !os(macOS)
    private var composeForm: some View {
        ScrollViewReader { proxy in
            Form {
                ForEach(ComposeFormSection.allCases, id: \.self) { section in
                    formSection(section)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                composeErrorBanner
            }
            .onChange(of: model.editorFocused) { _, focused in
                scrollBodyClearOfKeyboard(focused: focused, proxy: proxy)
            }
            // The other order: the editor takes focus with no keyboard up,
            // and the keyboard arrives afterwards. The scroll above then
            // ran against a form with no keyboard inset and clamped short,
            // so it has to run again once the inset lands.
            .onReceive(NotificationCenter.default.publisher(
                for: UIResponder.keyboardDidShowNotification
            )) { _ in
                scrollBodyClearOfKeyboard(focused: model.editorFocused, proxy: proxy)
            }
        }
    }

    /// Brings the body editor above the keyboard when it takes DOM focus.
    ///
    /// Nothing else reliably will: the editor is a `WKWebView`, so SwiftUI's
    /// focus system never sees it, and UIKit's own scroll-to-first-responder
    /// reaches the form inconsistently at best — see
    /// `ComposeBodyScrollPolicy`. The settle wait is what makes the scroll
    /// land: the keyboard's inset (and the accessory bar's) arrives a beat
    /// after focus does, and a scroll issued against the shorter
    /// pre-keyboard content clamps partway with nothing to scroll it the
    /// rest of the way (#1370).
    private func scrollBodyClearOfKeyboard(focused: Bool, proxy: ScrollViewProxy) {
        guard focused, ComposeBodyScrollPolicy.appMustScrollBodyIntoView else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(ComposeBodyScrollPolicy.bodyScrollTarget, anchor: .top)
            }
        }
    }

    /// The compose error, pinned between the toolbar and the scrolling
    /// form. It can't live in the form: the keyboard scrolls the form
    /// down, and a section inserted at the top then lands above the
    /// visible region with nothing to scroll it back (#938). Pinned, it
    /// is readable whatever the scroll offset — which is the whole point
    /// of keeping the composer up on a failed save (#903).
    @ViewBuilder
    private var composeErrorBanner: some View {
        if let errorMessage = model.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
                .overlay(alignment: .bottom) { Divider() }
                .accessibilityIdentifier("compose.error")
        }
    }

    /// Renders one section of `composeForm`. The order lives in
    /// `ComposeFormSection`, which documents why nothing actionable may
    /// follow `.message`.
    @ViewBuilder
    private func formSection(_ section: ComposeFormSection) -> some View {
        @Bindable var model = model
        switch section {
        case .from:
            Section("From") {
                FromPicker(
                    model: model,
                    onCreateAddress: { showNewAddressSheet = true }
                )
            }
        case .recipients:
            recipientsSection
        case .subject:
            Section("Subject") {
                TextField("Subject", text: $model.subject)
                    .accessibilityIdentifier("compose.subject")
            }
        case .attachments:
            if !model.attachments.isEmpty {
                Section("Attachments") {
                    ForEach(model.attachments) { attachment in
                        attachmentRow(attachment)
                    }
                    if model.attachmentTotalExceedsWarning {
                        attachmentSizeWarning
                    }
                }
            }
        case .message:
            Section("Message") {
                ComposerBody(model: model)
                    // What `scrollBodyClearOfKeyboard` scrolls to.
                    .id(ComposeBodyScrollPolicy.bodyScrollTarget)
            }
        }
    }

    private var recipientsSection: some View {
        @Bindable var model = model
        return Section("Recipients") {
            RecipientFieldWithSuggestions(
                label: "To",
                text: $model.toText,
                candidates: recipientCandidates,
                focusBinding: $focusedField,
                focusValue: Field.to,
                identifier: "compose.to",
                onContactsAccessChanged: reloadRecipientCandidates
            )
            RecipientFieldWithSuggestions(
                label: "Cc",
                text: $model.ccText,
                candidates: recipientCandidates,
                focusBinding: $focusedField,
                focusValue: Field.cc,
                identifier: "compose.cc",
                onContactsAccessChanged: reloadRecipientCandidates
            )
            RecipientFieldWithSuggestions(
                label: "Bcc",
                text: $model.bccText,
                candidates: recipientCandidates,
                focusBinding: $focusedField,
                focusValue: Field.bcc,
                identifier: "compose.bcc",
                onContactsAccessChanged: reloadRecipientCandidates
            )
        }
    }
    #endif

    #if os(macOS)
    /// Mail-style macOS layout: compact header grid up top, editor
    /// filling the rest of the window. Attachments and send errors
    /// render as bottom strips instead of Form sections.
    private var macLayout: some View {
        VStack(spacing: 0) {
            ComposeMacHeader(
                model: model,
                candidates: recipientCandidates,
                focusBinding: $focusedField,
                onCreateAddress: { showNewAddressSheet = true },
                onContactsAccessChanged: reloadRecipientCandidates
            )
            Divider()
            ComposerBody(model: model)
            if !model.attachments.isEmpty {
                Divider()
                macAttachmentStrip
            }
            if let errorMessage = model.errorMessage {
                Divider()
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
    }

    private var macAttachmentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.attachments) { attachment in
                attachmentRow(attachment)
            }
            if model.attachmentTotalExceedsWarning {
                attachmentSizeWarning
            }
        }
        .padding(10)
    }
    #endif
}
