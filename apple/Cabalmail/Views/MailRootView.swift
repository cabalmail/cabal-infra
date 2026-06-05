import SwiftUI
import UniformTypeIdentifiers
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
    @Environment(AppState.self) private var appState
    /// Non-nil while a message drag temporarily overrides the visible sidebar
    /// tab. When the user starts dragging a message while viewing Addresses,
    /// this flips the sidebar to Folders so they have somewhere to drop;
    /// clearing it on drag end falls the display back to the persisted tab
    /// (Addresses), satisfying "release flips back to addresses." Kept
    /// separate from `sidebarTabRaw` so the override never persists.
    @State private var sidebarDragOverride: SidebarTab?

    private var sidebarTab: SidebarTab {
        SidebarTab(rawValue: sidebarTabRaw) ?? .folders
    }

    /// The tab the sidebar actually shows: the drag override if one is
    /// active, otherwise the user's persisted choice.
    private var effectiveSidebarTab: SidebarTab {
        sidebarDragOverride ?? sidebarTab
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
                #if os(macOS)
                // Reserve the detail column's toolbar slots with disabled
                // stand-ins so the message-list toolbar (compose, reload)
                // stays anchored above the list pane. Without these,
                // NavigationSplitView's unified toolbar packs the list
                // items at the trailing edge — visually above the empty
                // detail pane — until a message is picked and the real
                // detail toolbar shoves them back into place.
                .toolbar { emptyDetailToolbar }
                #endif
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
        // Reveal Folders as drop targets the moment a message drag starts on
        // the Addresses tab, and fall back to the persisted tab when it ends.
        // The drag flag is flipped by the row's `.onDrag` (start) and by the
        // folder-row / catch-all drop handlers (end).
        .onChange(of: appState.messageDragInProgress) { _, dragging in
            if dragging {
                if effectiveSidebarTab == .addresses {
                    sidebarDragOverride = .folders
                }
            } else {
                sidebarDragOverride = nil
            }
        }
        // Catch-all drop target behind the whole split view: a message
        // released anywhere that isn't a folder row (the message list, the
        // reading pane, sidebar chrome) ends the drag so the sidebar flips
        // back. Folder rows are nested, more-specific drop targets, so a real
        // drop onto a folder is handled there and never reaches this. Returns
        // false - nothing is moved on a cancelled drag.
        .onDrop(of: [.cabalmailMessageMove], isTargeted: nil) { _ in
            Task { @MainActor in appState.endMessageDrag() }
            return false
        }
    }

    #if os(macOS)
    // Disabled stand-ins for `MessageDetailView`'s seven top-toolbar
    // buttons. Icons mirror the default state of each real button so the
    // empty pane looks like a quiescent reading pane rather than a row
    // of mystery placeholders. We don't bother reading Preferences for
    // the dispose icon — `.archive` is the default and a one-frame icon
    // flip when the real toolbar takes over is cheap.
    @ToolbarContentBuilder
    private var emptyDetailToolbar: some ToolbarContent {
        ToolbarItem { disabledToolbarButton(systemImage: "arrowshape.turn.up.left", label: "Reply") }
        ToolbarItem { disabledToolbarButton(systemImage: "envelope.badge", label: "Mark as read") }
        ToolbarItem { disabledToolbarButton(systemImage: "flag", label: "Flag") }
        ToolbarItem { disabledToolbarButton(systemImage: "eye.slash", label: "Show remote content") }
        ToolbarItem { disabledToolbarButton(systemImage: "doc.richtext", label: "Show reader view") }
        ToolbarItem { disabledToolbarButton(systemImage: "archivebox", label: "Archive") }
        ToolbarItem { disabledToolbarButton(systemImage: "ellipsis.circle", label: "More actions") }
    }

    private func disabledToolbarButton(systemImage: String, label: String) -> some View {
        Button {} label: {
            Image(systemName: systemImage)
                .accessibilityLabel(label)
        }
        .disabled(true)
    }
    #endif

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker(
                "Sidebar",
                selection: Binding(
                    get: { effectiveSidebarTab },
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

            switch effectiveSidebarTab {
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
