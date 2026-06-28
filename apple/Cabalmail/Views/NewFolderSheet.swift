import SwiftUI
import CabalmailKit

/// Sheet for creating a new folder. Captures a name and an optional parent
/// (picker seeded from the current folder list). Presented from the folder
/// sidebar's "New folder" toolbar button.
struct NewFolderSheet: View {
    let parents: [Folder]
    let onCreate: (String, String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var parent: String = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Projects", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Section("Parent") {
                    Picker("Parent folder", selection: $parent) {
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let chosenParent = parent.isEmpty ? nil : parent
        let succeeded = await onCreate(name, chosenParent)
        if succeeded { dismiss() }
    }
}
