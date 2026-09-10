import SwiftUI
import CabalmailKit

/// Subscribe to a feed: an address (a site works too; the server discovers
/// the feed) and the folder it goes in. Errors from the probe are worded by
/// `FeedErrorText` under the field; success hands the subscription back so
/// the sidebar can select it.
struct SubscribeFeedSheet: View {
    @Bindable var form: SubscribeFeedForm
    let folders: [RssFolder]
    let management: FeedManagementViewModel
    let onSubscribed: (RssSubscribeResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Subscribe to Feed")
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
                            if management.isBusy { ProgressView() } else { Text("Subscribe") }
                        }
                        .disabled(!form.canSubscribe || management.isBusy)
                        .accessibilityIdentifier("feed.subscribe.submit")
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        MacSheetForm {
            MacSheetSection(caption: "Address") {
                urlField.textFieldStyle(.roundedBorder)
            }
            MacSheetSection(caption: "Folder") {
                folderPicker.labelsHidden()
            }
            errorLabel
        }
        #else
        Form {
            Section("Address") { urlField }
            Section("Folder") { folderPicker }
            errorLabel
        }
        #endif
    }

    private var urlField: some View {
        TextField("Address", text: $form.url, prompt: Text("https://example.com/feed"))
            .labelsHidden()
            .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .onSubmit { if form.canSubscribe { Task { await submit() } } }
            .accessibilityIdentifier("feed.subscribe.url")
    }

    private var folderPicker: some View {
        FeedFolderPicker(title: "Folder", selection: $form.folderId, folders: folders)
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(ColorTokens.dangerFg)
                .accessibilityIdentifier("feed.subscribe.error")
        }
    }

    private func submit() async {
        guard let url = form.normalizedURL else { return }
        errorMessage = nil
        do {
            let result = try await management.subscribe(url: url, folderId: form.folderId)
            onSubscribed(result)
            dismiss()
        } catch {
            errorMessage = FeedErrorText.describe(error)
        }
    }
}

/// Folder picker shared by the feed sheets: top level first, then the tree
/// with each row indented by depth (a `Picker` menu has no hierarchy).
struct FeedFolderPicker: View {
    let title: String
    @Binding var selection: String
    let folders: [RssFolder]
    var excluding: String?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None (top level)").tag("")
            ForEach(FeedFolderChoices.choices(folders: folders, excluding: excluding)) { choice in
                Text(String(repeating: "    ", count: choice.depth) + choice.label).tag(choice.id)
            }
        }
    }
}
