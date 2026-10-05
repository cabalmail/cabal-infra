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
            content
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

    // MARK: - Platform layouts
    //
    // `Form` is kept for iOS/visionOS, where its grouped list style renders
    // the section headers as tidy group captions and leaves the rows inset.
    // On macOS the same `Form` promotes the picker's title into an external
    // leading label column and gives the rows no horizontal margins, so the
    // label landed on the sheet's left border and the name field stretched
    // flush to its right one (#1484). macOS therefore gets the hand-built
    // layout its sibling create sheet already uses (`NewAddressSheet`), via
    // the chrome they now share.

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macContent
        #else
        formContent
        #endif
    }

    #if os(macOS)
    private var macContent: some View {
        MacSheetForm {
            MacSheetSection(caption: "Name") {
                nameField
                    .textFieldStyle(.roundedBorder)
            }
            MacSheetSection(caption: "Parent") {
                parentPicker
                    // The caption above already says "Parent", so the
                    // picker's own title is redundant on screen; hidden, it
                    // survives for VoiceOver the way the name field's does.
                    .labelsHidden()
            }
        }
    }
    #else
    private var formContent: some View {
        Form {
            Section("Name") {
                nameField
            }
            Section("Parent") {
                parentPicker
            }
        }
    }
    #endif

    // The example belongs *inside* the empty field, so it is a prompt rather
    // than the field's title: macOS `Form` promotes a `TextField`'s title
    // into the leading label column, which drew "e.g. Projects" as the row's
    // label under the "Name" header (#1063). The title survives hidden, for
    // VoiceOver.
    private var nameField: some View {
        TextField("Name", text: $form.name, prompt: Text("e.g. Projects"))
            .labelsHidden()
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private var parentPicker: some View {
        Picker("Parent folder", selection: $form.parent) {
            Text("None (top level)").tag("")
            ForEach(parents) { folder in
                Text(folder.path).tag(folder.path)
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
