import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

/// Compose scene. macOS, iPadOS, and visionOS host this in a standalone
/// `WindowGroup` opened via `openWindow` (see `ComposeWindowScene`); iPhone
/// keeps it as a modal sheet so the user doesn't get torn away from the
/// mailbox they were just reading on a single-scene device.
///
/// The form is four labeled fields (From picker, To/Cc/Bcc tokens, subject,
/// dual-mode rich-text + Markdown body) plus an attachment strip and a Send
/// button. The primary affordance of the From picker is **"Create new
/// address…"** — per `docs/README.md`, minting a fresh subdomain-scoped
/// address per contact is Cabalmail's core idiom, so the picker never
/// silently preselects one and Send stays disabled until the user chooses.
struct ComposeView: View {
    /// SwiftUI focus targets. The body editor is a WKWebView and isn't part
    /// of the SwiftUI focus system; we route body focus through
    /// `RichTextEditorController.focusAtStart()` instead. The three
    /// recipient cases drive the autocomplete-suggestion list, which
    /// renders below whichever recipient field currently holds focus.
    enum Field: Hashable { case to, cc, bcc }

    @State var model: ComposeViewModel
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
    #if os(macOS)
    /// Intercepts the macOS window's red close button (and Cmd+W) so it
    /// routes through the same "Discard draft?" dialog as the toolbar
    /// Cancel button. iOS / visionOS / iPadOS dismiss via the modal sheet
    /// or scene close gesture and don't need this hook.
    @State private var closeCoordinator = ComposeWindowCloseCoordinator()
    #endif

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("From") {
                    FromPicker(
                        model: model,
                        onCreateAddress: { showNewAddressSheet = true }
                    )
                }
                Section("Recipients") {
                    RecipientFieldWithSuggestions(
                        label: "To",
                        text: $model.toText,
                        candidates: recipientCandidates,
                        focusBinding: $focusedField,
                        focusValue: Field.to
                    )
                    RecipientFieldWithSuggestions(
                        label: "Cc",
                        text: $model.ccText,
                        candidates: recipientCandidates,
                        focusBinding: $focusedField,
                        focusValue: Field.cc
                    )
                    RecipientFieldWithSuggestions(
                        label: "Bcc",
                        text: $model.bccText,
                        candidates: recipientCandidates,
                        focusBinding: $focusedField,
                        focusValue: Field.bcc
                    )
                }
                Section("Subject") {
                    TextField("Subject", text: $model.subject)
                }
                Section("Message") {
                    ComposerBody(model: model)
                }
                if !model.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(model.attachments) { attachment in
                            attachmentRow(attachment)
                        }
                        if model.attachmentTotalExceedsWarning {
                            let total = ByteCountFormatter.string(
                                fromByteCount: Int64(model.attachmentTotalBytes),
                                countStyle: .file
                            )
                            let warning = "Attachments total \(total). Many mail servers reject "
                                + "messages over 25 MB; delivery may fail."
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Message")
            #if os(iOS) || os(visionOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { toolbarContent }
            .task {
                await model.start()
                // Snapshot contacts once per compose surface. The list is
                // bounded by the user's address book; the per-keystroke
                // filter runs locally against this in-memory array so
                // typing doesn't take a CNContactStore hit per character.
                recipientCandidates = await appState.contactsStore.allEntries()
                #if os(macOS)
                // Capture the projected Binding so the closure can flip
                // dialog state from outside the view body. @State storage
                // outlives the View struct, so the binding stays valid
                // even when SwiftUI re-renders.
                let dialogBinding = $showDiscardConfirm
                closeCoordinator.onCloseAttempt = {
                    dialogBinding.wrappedValue = true
                }
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
                Button("Discard Draft", role: .destructive) {
                    Task {
                        #if os(macOS)
                        // Pre-approve the close so the dismissWindow call
                        // inside discard() doesn't get re-intercepted by
                        // the NSWindowDelegate.
                        closeCoordinator.allowsClose = true
                        #endif
                        await model.discard()
                    }
                }
                Button("Save Draft", role: .cancel) {
                    Task {
                        #if os(macOS)
                        closeCoordinator.allowsClose = true
                        #endif
                        let didClose = await model.cancel()
                        #if os(macOS)
                        // IMAP save failed: keep the user in the window so
                        // they can see the error banner and retry.
                        if !didClose {
                            closeCoordinator.allowsClose = false
                        }
                        #endif
                    }
                }
            } message: {
                Text("Keep a copy of the draft for later, or discard it now.")
            }
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
                showDiscardConfirm = true
            }
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
        #else
        Button {
            showFileImporter = true
        } label: {
            Image(systemName: "paperclip")
                .accessibilityLabel("Attach file")
        }
        #endif
    }

    // MARK: - Attachments

    #if os(iOS) || os(visionOS)
    private func ingestPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let filename = "photo-\(UUID().uuidString.prefix(8)).jpg"
            model.addAttachment(filename: filename, mimeType: "image/jpeg", data: data)
        }
        photoSelection = []
    }
    #endif
}
