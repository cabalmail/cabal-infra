import SwiftUI
import CabalmailKit

/// Folder-picker sheet for "Move to folder…" — closes a parity gap with
/// the React webmail, which has had arbitrary-folder move since 0.2.0
/// while the Apple clients had only Archive and Trash.
///
/// The sheet loads the user's subscribed folders on appear (filtered to
/// remove the source folder and any `\Noselect` containers), sorts them
/// through `FolderTree.sortUserTree` so the visible order matches the
/// sidebar, and indents each row by its tree depth so nested folders
/// read as nested. A `.searchable` filter lets the user narrow by name
/// or full path. Tapping a row hands the destination back to the caller
/// and dismisses; the caller owns the actual move and the optimistic UI.
struct MoveToFolderSheet: View {
    let currentFolder: Folder
    let client: CabalmailClient
    let onSelect: (Folder) -> Void
    let onCancel: () -> Void

    @State private var folders: [Folder] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var search: String = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Move to folder")
                #if os(iOS) || os(visionOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
                .searchable(text: $search, prompt: "Filter folders")
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 460)
        #endif
        .task { await load() }
    }

    private var content: some View {
        AsyncContentView(
            isLoading: isLoading,
            loadingLabel: "Loading folders…",
            errorMessage: errorMessage,
            retry: { Task { await load() } },
            content: {
                if visibleFolders.isEmpty {
                    ContentUnavailableView(
                        "No folders to move to",
                        systemImage: "folder",
                        description: Text(
                            search.isEmpty
                            ? "Subscribe to additional folders in the sidebar to use them as move targets."
                            : "No subscribed folder matches \"\(search)\"."
                        )
                    )
                } else {
                    List(visibleFolders) { folder in
                        Button {
                            onSelect(folder)
                        } label: {
                            FolderPickerRow(folder: folder)
                        }
                        .buttonStyle(.plain)
                    }
                    #if os(iOS) || os(visionOS)
                    .listStyle(.plain)
                    #endif
                }
            }
        )
    }

    private var visibleFolders: [Folder] {
        let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return folders }
        return folders.filter { folder in
            folder.path.lowercased().contains(normalized)
                || folder.name.lowercased().contains(normalized)
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let all = try await client.imapClient.listFolders()
            folders = sortForPicker(all)
        } catch {
            errorMessage = "Couldn't load folders: \(error.localizedDescription)"
        }
    }

    /// Subscribed folders minus the source and any `\Noselect` containers,
    /// then the shared sidebar order so the picker doesn't surprise. The
    /// `\Noselect` filter runs here rather than through
    /// `dropNoselectUserFolders` because the sheet drops such containers
    /// even when they carry a system name.
    private func sortForPicker(_ input: [Folder]) -> [Folder] {
        let candidates = input.filter { folder in
            folder.isSubscribed
                && folder.path != currentFolder.path
                && !folder.attributes.contains("\\Noselect")
        }
        return FolderTree.sidebarOrder(candidates)
    }
}
