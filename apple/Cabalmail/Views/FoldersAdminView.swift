import SwiftUI
import CabalmailKit

/// Folders tab — mirrors `react/admin/src/Folders/` (Phase 6, step 2).
///
/// Subscribe / unsubscribe per row controls whether the folder appears in
/// the Mail sidebar. "New Folder" opens a sheet with an optional parent
/// picker; delete surfaces through a swipe + confirmation for user folders
/// (system folders stay protected). All operations speak IMAP directly
/// against the authenticated session, per the Phase 3 transport split.
struct FoldersAdminView: View {
    @Environment(AppState.self) private var appState
    @State private var model: FoldersAdminViewModel?
    @State private var showNewFolderSheet = false
    @State private var pendingDelete: Folder?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Folders")
                .toolbar { toolbarContent }
                .refreshable { await model?.refresh() }
                .task { await ensureModel() }
                .sheet(isPresented: $showNewFolderSheet) { newFolderSheet }
                .confirmationDialog(
                    deleteDialogTitle,
                    isPresented: deleteDialogBinding,
                    presenting: pendingDelete,
                    actions: deleteDialogActions,
                    message: deleteDialogMessage
                )
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var content: some View {
        if let model {
            List {
                if let errorMessage = model.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                if model.isLoading && model.folders.isEmpty {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                } else {
                    folderSections(for: model)
                }
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func folderSections(for model: FoldersAdminViewModel) -> some View {
        let sorted = model.sortedForDisplay
        let subscribed = sorted.filter(\.isSubscribed)
        let unsubscribed = sorted.filter { !$0.isSubscribed }

        if !subscribed.isEmpty {
            Section("Subscribed") {
                ForEach(subscribed) { folder in
                    folderRow(folder, model: model)
                }
            }
        }
        if !unsubscribed.isEmpty {
            Section("Not Subscribed") {
                ForEach(unsubscribed) { folder in
                    folderRow(folder, model: model)
                }
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder, model: FoldersAdminViewModel) -> some View {
        folderRowBody(folder, model: model)
            .swipeActions(edge: .trailing) {
                if model.canDelete(folder) {
                    Button(role: .destructive) {
                        pendingDelete = folder
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .contextMenu { folderContextMenu(folder, model: model) }
    }

    @ViewBuilder
    private func folderRowBody(_ folder: Folder, model: FoldersAdminViewModel) -> some View {
        HStack {
            Image(systemName: iconName(for: folder))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.path)
                    .font(.body)
                if FoldersAdminViewModel.systemPaths.contains(folder.path) {
                    Text("System")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.canToggleSubscription(folder) {
                Toggle(
                    "Subscribed",
                    isOn: Binding(
                        get: { folder.isSubscribed },
                        set: { _ in Task { await model.toggleSubscription(folder) } }
                    )
                )
                .labelsHidden()
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: Folder, model: FoldersAdminViewModel) -> some View {
        if model.canToggleSubscription(folder) {
            Button {
                Task { await model.toggleSubscription(folder) }
            } label: {
                Label(
                    folder.isSubscribed ? "Unsubscribe" : "Subscribe",
                    systemImage: folder.isSubscribed ? "bell.slash" : "bell"
                )
            }
        }
        if model.canDelete(folder) {
            Button(role: .destructive) {
                pendingDelete = folder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button {
                showNewFolderSheet = true
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("New folder")
            }
            // Folder create needs a live folder list to seed the parent
            // picker, so the button is disabled until the initial refresh
            // lands. Typical round-trip is a few hundred ms.
            .disabled(model == nil)
        }
    }

    @ViewBuilder
    private var newFolderSheet: some View {
        if let model {
            NewFolderSheet(parents: model.possibleParents) { name, parent in
                await model.createFolder(name: name, parent: parent)
            }
        }
    }

    // MARK: - Confirmation dialog plumbing

    private var deleteDialogTitle: String {
        if let folder = pendingDelete {
            return "Delete \(folder.path)?"
        }
        return "Delete folder?"
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented { pendingDelete = nil }
            }
        )
    }

    @ViewBuilder
    private func deleteDialogActions(for folder: Folder) -> some View {
        Button("Delete", role: .destructive) {
            let target = folder
            pendingDelete = nil
            Task { await model?.deleteFolder(target) }
        }
        Button("Cancel", role: .cancel) {
            pendingDelete = nil
        }
    }

    @ViewBuilder
    private func deleteDialogMessage(for folder: Folder) -> some View {
        Text("Messages inside \(folder.path) will be deleted by the server. This can't be undone.")
    }

    // MARK: - Helpers

    private func iconName(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "doc"
        case "Trash":   return "trash"
        case "Junk":    return "xmark.bin"
        case "Archive": return "archivebox"
        default:
            return folder.attributes.contains("\\Noselect") ? "folder.badge.minus" : "folder"
        }
    }

    private func ensureModel() async {
        if model == nil, let client = appState.client {
            model = FoldersAdminViewModel(client: client)
            await model?.refresh()
        }
    }
}

/// Sheet for creating a new folder. Captures a name and an optional parent
/// (picker seeded from the current folder list).
private struct NewFolderSheet: View {
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
