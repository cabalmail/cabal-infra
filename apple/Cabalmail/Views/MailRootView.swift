import SwiftUI
import CabalmailKit

/// Root of the signed-in navigation.
///
/// Single `NavigationSplitView` serves every platform — iPhone compact
/// collapses it to a stack push sequence automatically. Selection is lifted
/// to this view so the three columns stay in sync.
///
/// `.id(...)` on the content and detail columns forces SwiftUI to rebuild
/// the view (and its `@State` / `@Observable` view models) when selection
/// changes. Without it, the same view instance is reused with a new folder
/// or envelope prop and its one-shot `.task` never re-fires — which is the
/// bug that made "select a second folder" do nothing on the split layout.
struct MailRootView: View {
    @State private var selectedFolder: Folder?
    @State private var selectedEnvelope: Envelope?

    var body: some View {
        NavigationSplitView {
            FolderListView(
                selection: $selectedFolder,
                onFoldersLoaded: { folders in
                    // Default-select INBOX the first time the list arrives.
                    // The Compose button lives on the message-list toolbar,
                    // so a nil-selection state would leave the user no way
                    // to start a new message. INBOX is always present
                    // (`FolderListViewModel.sortForSidebar` pins it first).
                    guard selectedFolder == nil else { return }
                    selectedFolder = folders.first { inbox in
                        inbox.path.caseInsensitiveCompare("INBOX") == .orderedSame
                    } ?? folders.first
                }
            )
        } content: {
            if let selectedFolder {
                MessageListView(folder: selectedFolder, selection: $selectedEnvelope)
                    .id(selectedFolder.path)
            } else {
                ContentUnavailableView(
                    "Select a folder",
                    systemImage: "sidebar.left",
                    description: Text("Pick a mailbox from the sidebar to browse messages.")
                )
            }
        } detail: {
            if let selectedFolder, let selectedEnvelope {
                MessageDetailView(
                    folder: selectedFolder,
                    envelope: selectedEnvelope,
                    onDispose: { self.selectedEnvelope = nil }
                )
                .id("\(selectedFolder.path)#\(selectedEnvelope.uid)")
            } else {
                ContentUnavailableView(
                    "No message selected",
                    systemImage: "envelope",
                    description: Text("Pick a message from the list to read it.")
                )
            }
        }
        // Clearing the envelope selection when the folder changes keeps the
        // detail column from briefly rendering an old message against the
        // new mailbox.
        .onChange(of: selectedFolder) { _, _ in
            selectedEnvelope = nil
        }
    }
}
