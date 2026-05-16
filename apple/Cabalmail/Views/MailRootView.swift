import SwiftUI
import CabalmailKit

/// Root of the signed-in navigation.
///
/// Single `NavigationSplitView` serves every platform — iPhone compact
/// collapses it to a stack push sequence automatically. Selection is lifted
/// to this view so the three columns stay in sync.
///
/// `.id(...)` on the content column forces SwiftUI to rebuild the message
/// list (and its `@State` / `@Observable` view model) when the folder
/// selection changes. Without it, the same view instance is reused with a
/// new folder prop and its one-shot `.task` never re-fires — which is the
/// bug that made "select a second folder" do nothing on the split layout.
///
/// The detail column intentionally does NOT carry an `.id(...)` keyed on
/// the envelope UID. On iPhone, `NavigationSplitView`'s compact-collapse
/// adapter materialises the detail subtree in two structural slots when
/// the .id changes (once as the pushed stack destination, once as the in-
/// place detail branch), giving `MessageDetailView` two `@State` buckets
/// and two body-fetch Tasks per tap. Keeping a stable identity and
/// reacting to envelope changes via `.onChange(of: envelope.uid)` inside
/// `MessageDetailView` produces a single instance per tap.
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
    @AppStorage("cabalmail.sidebar.tab") private var sidebarTabRaw: String = SidebarTab.folders.rawValue

    private var sidebarTab: SidebarTab {
        SidebarTab(rawValue: sidebarTabRaw) ?? .folders
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
                    onClearAddressFilter: { selectedAddress = nil }
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
            if let selectedFolder, let selectedEnvelope {
                MessageDetailView(
                    folder: selectedFolder,
                    envelope: selectedEnvelope
                )
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
