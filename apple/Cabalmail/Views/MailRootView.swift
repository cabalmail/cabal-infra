import SwiftUI
import CabalmailKit

/// Root of the signed-in navigation.
///
/// Branched on horizontal size class on iOS / visionOS so iPhone-compact
/// uses an explicit `NavigationStack` with value-driven destinations
/// rather than letting `NavigationSplitView`'s compact-collapse adapter
/// auto-collapse the three columns. The auto-collapse path materialises
/// the detail subtree in two structural slots when an envelope is
/// selected (see #403 follow-up), giving `MessageDetailView` two
/// `@State` buckets and two body-fetch Tasks per tap; an explicit stack
/// pushes a single destination instance.
///
/// macOS, iPad in regular width, and visionOS continue to use the
/// `NavigationSplitView` layout where all three columns render side-by-
/// side and there is no collapse adapter to fight.
///
/// `.id(...)` on the content column (only used in the split layout) forces
/// SwiftUI to rebuild the message list and its `@State` view model when
/// the folder selection changes. Without it, the same instance is reused
/// with a new folder prop and its one-shot `.task` never re-fires — which
/// was the bug that made "select a second folder" do nothing on the
/// split layout. The stack layout doesn't need `.id()` because each
/// folder push gets its own `MessageListView` destination instance.
///
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
    @State private var detailModelStore = MessageDetailModelStore()
    @AppStorage("cabalmail.sidebar.tab") private var sidebarTabRaw: String = SidebarTab.folders.rawValue

    #if os(iOS) || os(visionOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var sidebarTab: SidebarTab {
        SidebarTab(rawValue: sidebarTabRaw) ?? .folders
    }

    var body: some View {
        platformBody
            .environment(detailModelStore)
            // Clearing the envelope selection AND any active address filter
            // when the folder changes keeps the detail column from briefly
            // rendering an old message against the new mailbox, and matches
            // the plan's "switching folders clears the filter" rule.
            .onChange(of: selectedFolder) { _, _ in
                selectedEnvelope = nil
                selectedAddress = nil
                detailModelStore.clear()
            }
            .onChange(of: selectedEnvelope) { _, newValue in
                if newValue == nil { detailModelStore.clear() }
            }
    }

    @ViewBuilder
    private var platformBody: some View {
        #if os(iOS) || os(visionOS)
        if horizontalSizeClass == .compact {
            compactStackBody
        } else {
            splitBody
        }
        #else
        splitBody
        #endif
    }

    // MARK: - Layouts

    @ViewBuilder
    private var splitBody: some View {
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
    }

    /// iPhone-compact layout. The sidebar (folder / address picker) is
    /// the root; selecting a folder pushes `MessageListView`; selecting
    /// an envelope pushes `MessageDetailView`. Both pushes are driven
    /// by `navigationDestination(item:)` against the same `@State`
    /// selection bindings the split layout already uses, so the rest
    /// of the app (`MessageListView`'s selection binding, `AppState`
    /// signals) keeps working unchanged.
    @ViewBuilder
    private var compactStackBody: some View {
        NavigationStack {
            sidebar
                .navigationDestination(item: $selectedFolder) { folder in
                    MessageListView(
                        folder: folder,
                        selection: $selectedEnvelope,
                        addressFilter: selectedAddress?.address,
                        onClearAddressFilter: { selectedAddress = nil }
                    )
                    .navigationDestination(item: $selectedEnvelope) { envelope in
                        MessageDetailView(
                            folder: folder,
                            envelope: envelope
                        )
                    }
                }
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
