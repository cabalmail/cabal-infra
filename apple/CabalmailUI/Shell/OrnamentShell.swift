#if os(visionOS)
import SwiftUI
import CabalmailKit

/// The visionOS shell: a floating leading tab bar.
///
/// On visionOS a `TabView` is presented as an ornament docked to the window's
/// leading edge — the spatial idiom for top-level navigation. The tabs are
/// `CompactTab.tabs(for: .ornament)`, the tab layout's list with Folders
/// added, and Search a plain tab rather than the phone's search role:
///
/// - **Mail** — the message list + reader for the selected folder. There is no
///   folder sidebar here; the Folders tab is how the mailbox in view changes.
/// - **Folders** — the folder list. Picking a folder drives the Mail tab's
///   message list and switches back to Mail so the messages are front-and-center.
/// - **Addresses** — the shared `AddressListView` (request / revoke / favorite).
/// - **Settings** — general preferences.
/// - **Search** — cross-folder search.
///
/// This replaces the earlier visionOS path, which reused the iPad
/// `MailRootView`: its folders lived in a show/hide `NavigationSplitView`
/// sidebar whose reveal toggle visionOS never surfaced, leaving no discoverable
/// way to reach the folder list.
struct OrnamentShell: View {
    @Environment(AppState.self) private var appState
    @Environment(SceneNavigator.self) private var navigator

    /// This tab view's identity as the window's mail tree. visionOS has no
    /// layout swap, so it is the window's only one: it lands at launch and
    /// owns the folder and message the Mail and Folders tabs share.
    @State private var tree = UUID()

    /// The visible tab, through the navigator: a Folders pick, the ⌘,
    /// command and a resume tap switch tabs there, and a switch notes the
    /// section on the resume session. Seeded from the stored session, so a
    /// launch that ended in the feed reader opens on Feeds. Each tab's content
    /// names its tab (`commandTab`), so only the tab in front answers the menus.
    private var selection: Binding<CompactTab> {
        Binding(get: { navigator.compactTab }, set: { navigator.showTab($0) })
    }

    /// The Folders tab's selection: the window's folder. A pick there also
    /// switches to Mail (`SceneNavigator`).
    private var folderSelection: Binding<Folder?> {
        Binding(get: { navigator.folder(in: tree) }, set: { navigator.selectFolder($0) })
    }

    var body: some View {
        TabView(selection: selection) {
            ForEach(CompactTab.tabs(for: .ornament), id: \.self) { tab in
                if tab.role(in: .ornament) == .search {
                    Tab(value: tab, role: .search) {
                        content(for: tab)
                            .environment(\.commandTab, tab)
                    }
                } else {
                    Tab(LocalizedStringKey(tab.title), systemImage: tab.systemImage, value: tab) {
                        content(for: tab)
                            .environment(\.commandTab, tab)
                    }
                }
            }
        }
        // Land at launch regardless of which tab is showing, so the message
        // list isn't empty before the user ever visits Folders. The Folders
        // tab's own list loads lazily on first appearance, so the folder list
        // that finishes the landing is fetched from here.
        .task {
            await navigator.mailTreeAppeared(tree, isWide: false)
            await loadFoldersIfNeeded()
        }
        // ⌘, opens Settings — its own tab here, rather than the iPad sheet.
        .answersCommand(.settings) {
            navigator.showTab(.settings)
        }
    }

    @ViewBuilder
    private func content(for tab: CompactTab) -> some View {
        switch tab {
        case .mail: VisionMailPane(tree: tree)
        case .folders: foldersTab
        case .feeds: FeedRootView()
        case .addresses: AddressManagementTab()
        case .settings: SettingsView()
        case .search: SearchView()
        }
    }

    /// Folders tab: the shared `FolderListView` bound to the window's folder.
    /// No `onFoldersLoaded` here — the landing's folder list comes from
    /// `loadFoldersIfNeeded` (which runs even while this tab is unmounted).
    @ViewBuilder
    private var foldersTab: some View {
        NavigationStack {
            FolderListView(selection: folderSelection, externalFilter: nil)
        }
    }

    /// Fetches the folder list for the navigator: it swaps the fetched folder
    /// in for the landing's provisional one, or falls back to INBOX if the
    /// folder no longer exists (`SceneNavigator.foldersLoaded`). Sourced from
    /// its own `FolderListViewModel` because there's no always-mounted
    /// sidebar to hand one over. The Feeds tab restores its own position
    /// (`FeedRootView`).
    private func loadFoldersIfNeeded() async {
        guard navigator.loadedFolders.isEmpty, let client = appState.client else { return }
        let model = FolderListViewModel(client: client, mailStore: appState.mailStore)
        await model.loadFolderList()
        // A saved copy drawn offline can lag the server; reconcile against a
        // live list only.
        guard !model.folders.isEmpty, !model.isShowingSavedCopy else { return }
        navigator.foldersLoaded(model.folders)
    }
}

/// Mail tab body: a two-column list + reader for the window's folder, with
/// no folder sidebar (folders are their own tab). The folder and the open
/// message are the navigator's, which records the cross-client cursor as the
/// user moves through them, as on the other layouts.
private struct VisionMailPane: View {
    let tree: UUID
    @Environment(SceneNavigator.self) private var navigator
    /// How many messages the list currently has selected. Drives the "N
    /// messages selected" reading-pane placeholder during a multi-selection.
    @State private var listSelectionCount = 0

    private var selectedFolder: Folder? { navigator.folder(in: tree) }
    private var selectedEnvelope: Envelope? { navigator.envelope(in: tree) }

    /// The list's selection, through the navigator. The Mail tab has no
    /// search of its own (Search is a tab), so the open message is always
    /// the folder's.
    private var envelopeSelection: Binding<Envelope?> {
        Binding(get: { selectedEnvelope }, set: { navigator.selectMessage($0, isSearching: false, from: tree) })
    }

    var body: some View {
        NavigationSplitView {
            listColumn
        } detail: {
            detailColumn
        }
        // Switching folders drops any multi-selection with the old mailbox.
        // A same-path change is the landing's metadata reconcile — same
        // mailbox, so the selection stays.
        .onChange(of: selectedFolder?.path) {
            listSelectionCount = 0
        }
        // Keep the Message menu's commands validated against what they'd
        // actually act on (see `MessageMenuAvailability`), as the other
        // shells' mail does (#1995).
        .reportsMessageMenuAvailability(
            selectedCount: listSelectionCount,
            hasOpenMessage: selectedEnvelope != nil
        )
    }

    @ViewBuilder
    private var listColumn: some View {
        if let selectedFolder {
            MessageListView(
                scope: .folder(selectedFolder),
                selection: envelopeSelection,
                onSelectionCountChanged: { listSelectionCount = $0 },
                // The list's folder-switch menu picks the window's folder
                // exactly as a Folders-tab pick does.
                onSwitchFolder: { navigator.selectFolder($0) }
            )
            .id(selectedFolder.path)
        } else {
            ContentUnavailableView(
                "Select a folder",
                systemImage: "folder",
                description: Text("Pick a folder from the Folders tab to browse messages.")
            )
        }
    }

    private var detailColumn: some View {
        MailReaderColumn(
            selectionCount: listSelectionCount,
            envelope: selectedEnvelope,
            sidebarFolder: selectedFolder
        )
    }
}
#endif
