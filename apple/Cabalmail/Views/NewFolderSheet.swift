import SwiftUI
import CabalmailKit

/// Sheet for creating a new folder. Captures a name and an optional parent
/// (picker seeded from the current folder list). Presented from the folder
/// sidebar's "New folder" toolbar button.
///
/// The typed name and the chosen parent live in `NewFolderForm`, owned by the
/// presenting view — sheet-local `@State` doesn't survive the body being
/// re-created when the parent picker's menu dismisses (#889).
struct NewFolderSheet: View {
    let parents: [Folder]
    @Bindable var form: NewFolderForm
    let onCreate: (String, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    // The example belongs *inside* the empty field, so it is
                    // a prompt rather than the field's title: macOS `Form`
                    // promotes a `TextField`'s title into the leading label
                    // column, which drew "e.g. Projects" as the row's label
                    // under the "Name" header (#1063). The title survives
                    // hidden, for VoiceOver.
                    TextField("Name", text: $form.name, prompt: Text("e.g. Projects"))
                        .labelsHidden()
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section("Parent") {
                    Picker("Parent folder", selection: $form.parent) {
                        Text("None (top level)").tag("")
                        ForEach(parents) { folder in
                            Text(folder.path).tag(folder.path)
                        }
                    }
                }
            }
            .navigationTitle("New Folder")
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
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(!form.canCreate || isSubmitting)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let succeeded = await onCreate(form.name, form.chosenParent)
        if succeeded { dismiss() }
    }
}
