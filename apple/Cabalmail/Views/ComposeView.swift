import SwiftUI
import CabalmailKit
#if os(iOS) || os(visionOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

/// Compose scene — presented as a sheet on iPhone and as a full-height
/// modal on iPad / macOS / visionOS. Phase 5 keeps this unified; Phase 7
/// polish moves macOS and iPad to their own windows via `openWindow`.
///
/// The form is four labeled fields (From picker, To/Cc/Bcc tokens, subject,
/// plain-text body) plus an attachment strip and a Send button. The primary
/// affordance of the From picker is **"Create new address…"** — per
/// `docs/README.md`, minting a fresh subdomain-scoped address per contact
/// is Cabalmail's core idiom, so the picker never silently preselects one
/// and Send stays disabled until the user chooses.
struct ComposeView: View {
    @State var model: ComposeViewModel
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
                    recipientField("Cc", text: $model.ccText)
                    recipientField("Bcc", text: $model.bccText)
                }
                Section("Subject") {
                    TextField("Subject", text: $model.subject)
                }
                Section("Message") {
                    TextEditor(text: $model.body)
                        .frame(minHeight: 180)
                        .font(.body)
                }
                if !model.attachments.isEmpty {
                    Section("Attachments") {
                        ForEach(model.attachments) { attachment in
                            attachmentRow(attachment)
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
