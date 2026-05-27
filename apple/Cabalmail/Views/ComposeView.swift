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
    /// `RichTextEditorController.focusAtStart()` instead.
    enum Field: Hashable { case to }

    @State var model: ComposeViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focusedField: Field?
    @State private var showNewAddressSheet = false
    @State private var showDiscardConfirm = false
    #if os(iOS) || os(visionOS)
    @State private var showPhotoPicker = false
    @State private var photoSelection: [PhotosPickerItem] = []
    #endif
    @State private var showFileImporter = false

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
                    recipientField("To", text: $model.toText)
                        .focused($focusedField, equals: .to)
                    recipientField("Cc", text: $model.ccText)
                    recipientField("Bcc", text: $model.bccText)
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
                    Task { await model.discard() }
                }
                Button("Save Draft", role: .cancel) {
                    Task { await model.cancel() }
                }
            } message: {
                Text("Keep a copy of the draft for later, or discard it now.")
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func recipientField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text, axis: .vertical)
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.emailAddress)
            #endif
    }

    @ViewBuilder
    private func attachmentRow(_ attachment: ComposeViewModel.ComposeAttachment) -> some View {
        HStack {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text(attachment.filename)
                    .font(.subheadline)
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(attachment.data.count),
                    countStyle: .file
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.removeAttachment(id: attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

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
                    let sent = await model.send()
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

    private func ingestFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            for url in urls {
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                model.addAttachment(
                    filename: url.lastPathComponent,
                    mimeType: mimeType(for: url),
                    data: data
                )
            }
        case .failure(let error):
            model.errorMessage = "Couldn't attach file: \(error.localizedDescription)"
        }
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
