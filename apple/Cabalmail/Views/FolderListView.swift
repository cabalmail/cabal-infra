import SwiftUI
import CabalmailKit

/// Folder sidebar (Phase 4 step 3).
///
/// Selecting a folder pushes a `MessageListView` in the iPhone `NavigationStack`
/// and replaces the middle column in the iPad/macOS/visionOS split view. The
/// selection state is owned here so the parent split view can bind to it.
struct FolderListView: View {
    @Environment(AppState.self) private var appState
    @State private var model: FolderListViewModel?
    @Binding var selection: Folder?

    var body: some View {
        List(selection: $selection) {
            if let model {
                if model.isLoading && model.folders.isEmpty {
                    ProgressView("Loading folders…")
                }
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                ForEach(model.folders) { folder in
                    row(for: folder, unread: model.unreadCounts[folder.path] ?? 0)
                        .tag(folder)
                }
            }
        }
        .navigationTitle("Mailboxes")
        .refreshable {
            await model?.refresh()
        }
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    Task { await appState.signOut() }
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .accessibilityLabel("Sign Out")
                }
            }
        }
        .task {
            if model == nil, let client = appState.client {
                model = FolderListViewModel(client: client)
                await model?.refresh()
            }
        }
    }

    @ViewBuilder
    private func row(for folder: Folder, unread: Int) -> some View {
        HStack {
            Image(systemName: iconName(for: folder))
                .foregroundStyle(.tint)
            Text(folder.name)
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
    }

    private func iconName(for folder: Folder) -> String {
        switch folder.path {
        case "INBOX":   return "tray"
        case "Sent":    return "paperplane"
        case "Drafts":  return "doc"
        case "Trash":   return "trash"
        case "Junk":    return "xmark.bin"
        case "Archive": return "archivebox"
        default:        return "folder"
        }
    }
}
