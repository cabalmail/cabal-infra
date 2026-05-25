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
/// Which list the sidebar is showing — toggled by a segmented control
/// pinned above the list itself. Persisted across launches via
/// `@AppStorage` so the user lands on the tab they last used.
enum SidebarTab: String, CaseIterable, Identifiable {
    case folders
    case addresses
    var id: String { rawValue }
}

struct MailRootView: View {
    @State private var selectedFolder: Folder?
    @State private var selectedEnvelope: Envelope?
    @State private var selectedAddress: Address?
    /// Override for the message detail's folder context when the selected
    /// envelope is a cross-folder search result. `MessageListView` reports
    /// the source folder via `onSearchResultSelected`; we wrap it in a
    /// synthetic `Folder` so `MessageDetailView`'s mark-read / archive /
    /// move operations target the message's true mailbox rather than the
    /// sidebar's current selection. Nil for same-folder rows and folder-
    /// mode lists, so `detailFolder` falls back to `selectedFolder`.
    @State private var crossFolderDetail: Folder?
    @AppStorage("cabalmail.sidebar.tab") private var sidebarTabRaw: String = SidebarTab.folders.rawValue

    private var sidebarTab: SidebarTab {
        SidebarTab(rawValue: sidebarTabRaw) ?? .folders
    }

    /// Folder that drives `MessageDetailView`. Cross-folder search results
    /// override the sidebar selection; everything else uses it directly.
    private var detailFolder: Folder? {
        crossFolderDetail ?? selectedFolder
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            if let selectedFolder {
                MessageListView(
                    folder: selectedFolder,
                    selection: $selectedEnvelope,
                    addressFilter: selectedAddress?.address,
                    onClearAddressFilter: { selectedAddress = nil },
                    onSearchResultSelected: { sourceFolderPath in
                        crossFolderDetail = sourceFolderPath.map { Folder(path: $0) }
                    }
                )
                .id(selectedFolder.path)
            } else {
                ContentUnavailableView(
                    "Select a folder",
                    systemImage: "sidebar.left",
                    description: Text("Pick a mailbox from the sidebar to browse messages.")
                )
            }
        } detail: {
            if let folder = detailFolder, let selectedEnvelope {
                MessageDetailView(
                    folder: folder,
                    envelope: selectedEnvelope
                )
                .id("\(folder.path)#\(selectedEnvelope.uid)")
            } else {
                ContentUnavailableView(
                    "No message selected",
                    systemImage: "envelope",
                    description: Text("Pick a message from the list to read it.")
                )
            }
        }
        // Clearing the envelope selection AND any active address filter when
        // the folder changes keeps the detail column from briefly rendering
        // an old message against the new mailbox, and matches the plan's
        // "switching folders clears the filter" rule.
        .onChange(of: selectedFolder) { _, _ in
            selectedEnvelope = nil
            selectedAddress = nil
            crossFolderDetail = nil
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker(
                "Sidebar",
                selection: Binding(
                    get: { sidebarTab },
                    set: { sidebarTabRaw = $0.rawValue }
                )
            ) {
                Text("Folders").tag(SidebarTab.folders)
                Text("Addresses").tag(SidebarTab.addresses)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch sidebarTab {
            case .folders:
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
            case .addresses:
                AddressListView(selection: $selectedAddress)
            }
        }
    }
}
