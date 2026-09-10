import SwiftUI
import CabalmailKit

/// Create a feed folder, or rename / move one (`form.editing` set). The
/// parent picker leaves out the folder being edited and everything under
/// it, so a folder can't be moved into itself.
struct FeedFolderSheet: View {
    @Bindable var form: FeedFolderForm
    let folders: [RssFolder]
    let management: FeedManagementViewModel
    let onDone: (RssFolder) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var isEditing: Bool { form.editing != nil }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(isEditing ? "Edit Folder" : "New Feed Folder")
                #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await submit() }
                        } label: {
                            if management.isBusy { ProgressView() } else { Text(isEditing ? "Save" : "Create") }
                        }
                        .disabled(!form.canSave || management.isBusy)
                        .accessibilityIdentifier("feed.folder.submit")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        MacSheetForm {
            MacSheetSection(caption: "Name") {
                nameField.textFieldStyle(.roundedBorder)
            }
            MacSheetSection(caption: "Parent") {
                parentPicker.labelsHidden()
            }
            errorLabel
        }
        #else
        Form {
            Section("Name") { nameField }
            Section("Parent") { parentPicker }
            errorLabel
        }
        #endif
    }

    private var nameField: some View {
        TextField("Name", text: $form.name, prompt: Text("e.g. News"))
            .labelsHidden()
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { if form.canSave { Task { await submit() } } }
            .accessibilityIdentifier("feed.folder.name")
    }

    private var parentPicker: some View {
        FeedFolderPicker(title: "Parent folder", selection: $form.parentId, folders: folders,
                         excluding: form.editing?.folderId)
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(ColorTokens.dangerFg)
        }
    }

    private func submit() async {
        errorMessage = nil
        do {
            let folder: RssFolder
            if let editing = form.editing {
                guard let update = form.folderUpdate else { dismiss(); return }
                folder = try await management.updateFolder(editing, update)
            } else {
                folder = try await management.createFolder(name: form.name.trimmingCharacters(in: .whitespaces),
                                                           parentId: form.parentId)
            }
            onDone(folder)
            dismiss()
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
    }
}
