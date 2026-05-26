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

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading folders…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry") {
                    Task { await load() }
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleFolders.isEmpty {
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
                    row(for: folder)
                }
                .buttonStyle(.plain)
            }
            #if os(iOS) || os(visionOS)
            .listStyle(.plain)
            #endif
        }
    }

    @ViewBuilder
    private func row(for folder: Folder) -> some View {
        let depth = FolderTree.depth(for: folder)
        HStack(spacing: 8) {
            Image(systemName: icon(for: folder))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.body)
                if depth > 0 {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
    }

    private func icon(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "pencil.line"
        case "Trash":   return "trash"
        case "Junk":    return "exclamationmark.shield"
        case "Archive": return "archivebox"
        default:        return "folder"
        }
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
    /// sorted with INBOX pinned first, then user folders in tree order, then
    /// the remaining system folders. Same shape as the sidebar so the
    /// picker order doesn't surprise.
    private func sortForPicker(_ input: [Folder]) -> [Folder] {
        let candidates = input.filter { folder in
            folder.isSubscribed
                && folder.path != currentFolder.path
                && !folder.attributes.contains("\\Noselect")
        }
        let systemNames: Set<String> = ["Sent", "Drafts", "Trash", "Junk", "Archive"]
        let inbox = candidates.filter { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        }
        let system = candidates
            .filter { systemNames.contains($0.path) }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let userFolders = candidates.filter { folder in
            !inbox.contains(folder) && !system.contains(folder)
        }
        return inbox + FolderTree.sortUserTree(userFolders) + system
    }
}
