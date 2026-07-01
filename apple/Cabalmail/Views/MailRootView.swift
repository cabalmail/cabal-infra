import SwiftUI
import CabalmailKit
#if os(iOS)
import UIKit
#endif

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
    /// How many messages the list currently has selected, reported by
    /// `MessageListView` on wide/keyboard layouts. Drives the "N messages
    /// selected" reading-pane placeholder when a multi-selection is active;
    /// stays 0 on compact iPhone (single-selection there).
    @State private var listSelectionCount = 0
    /// Which column the collapsed (iPhone-compact) navigation shows. The
    /// virtualized message list is a `ScrollView`, not a `List(selection:)`,
    /// so NavigationSplitView no longer auto-pushes the reader when a row is
    /// tapped on compact (it works on regular width / iPad, where all columns
    /// are visible). Driving this binding restores the push: a selected
    /// message shows `.detail`, a selected folder `.content`, and navigating
    /// back drops the selection. Ignored on regular-width layouts.
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar
    /// Wide-layout (iPad-regular) sidebar visibility. Defaults to `.doubleColumn`
    /// — the folder/address sidebar starts COLLAPSED — so the message list is the
    /// leftmost tile of the split. That is the only configuration in which the
    /// list rows' leading swipe (read/unread) reveals at a normal drag distance:
    /// when the sidebar is tiled to the list's left (`twoBesideSecondary`), the
    /// split view's interactive column gesture out-arbitrates the row's leading
    /// swipe, so the blue action only appears after an unreasonably long drag.
    /// Collapsing the sidebar and revealing it on demand as an overlay (see
    /// `SplitOverlayConfigurator`) keeps both swipes live in the reading state.
    /// macOS keeps the sidebar visible (`.all`): a NavigationSplitView there is
    /// AppKit-backed with no UISplitViewController gesture conflict, and it's a
    /// desktop multi-pane window. Ignored on compact iPhone (navigates via
    /// `compactColumn`).
    #if os(macOS)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #else
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn
    #endif
    @AppStorage("cabalmail.sidebar.tab") private var sidebarTabRaw: String = SidebarTab.folders.rawValue
    /// Persisted width of the message-list (content) column in the wide
    /// (regular-width iPad / visionOS) three-column layout. `NavigationSplitView`
    /// doesn't report where a user drags the native list-reader divider, so the
    /// column is pinned to this width and a `ColumnResizeHandle` on its trailing
    /// edge drives it — letting the chosen split survive cold launches. macOS
    /// keeps its native, self-persisting dividers. Stored as `Double` because
    /// `@AppStorage` has no `CGFloat` overload.
    @AppStorage("cabalmail.layout.listColumnWidth") private var listColumnWidthStored: Double = 360
    /// Live width of the whole split view, read via `.onGeometryChange`, used to
    /// clamp the list column so the reading pane always keeps a minimum width.
    @State private var splitWidth: CGFloat = 0
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    /// Drives the cross-client cursor reconcile: returning to the foreground
    /// re-reads the server cursor and, if another client moved it on, offers
    /// the "pick up where you left off" toast. The initial launch transition
    /// doesn't fire `.onChange`, so a cold launch offers its own resume toast
    /// from the folder-load path (`landOnInboxAndOfferResume`) instead.
    @Environment(\.scenePhase) private var scenePhase
    /// Global-search model for the wide (iPad-regular / macOS) layout, owned
    /// here so the sidebar search field and the content column share one query
    /// and result set. The compact-width analogue is `SearchView` (the iPhone
    /// `Tab(role: .search)`); there's no bottom tab bar here, so search is
    /// reached from the sidebar instead.
    @State private var searchModel: MessageListViewModel?
    /// Focus on the sidebar search field. Drives the content-column swap: while
    /// the field is focused (or holds a query / active search) the content
    /// column shows results instead of the selected folder.
    @FocusState private var searchFieldFocused: Bool
    /// Per-context list-filter text for the wide sidebar. On macOS / iPad-regular
    /// this view renders the "Filter folders" / "Filter addresses" field itself
    /// (below the section tabs) so it sits under the global search rather than
    /// being hoisted above it by `.searchable(placement: .sidebar)`; the binding
    /// is handed to the list view. Unused on compact, where the list keeps its
    /// own searchable.
    @State private var folderListFilter = ""
    @State private var addressListFilter = ""
    /// Whether this is the wide single-rail sidebar (macOS, iPad-regular) where
    /// `.searchable(placement: .sidebar)` pins fields to the column top. Uses the
    /// `showsSettingsGear` flag rather than `horizontalSizeClass` because the
    /// sidebar column reports a compact size class even on a regular-width iPad.
    #if !os(macOS)
    @Environment(\.showsSettingsGear) private var showsSettingsGear
    #endif
    private var isWideSidebar: Bool {
        #if os(macOS)
        return true
        #else
        return showsSettingsGear
        #endif
    }
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

    /// Whether the content column should show search results rather than the
    /// selected folder: the sidebar field is focused, holds a query, or a
    /// search is currently active.
    private var isSearching: Bool {
        guard let searchModel else { return false }
        return searchFieldFocused || !searchModel.searchQuery.isEmpty || searchModel.isSearchActive
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { searchModel?.searchQuery ?? "" },
            set: { searchModel?.searchQuery = $0 }
        )
    }

    /// Content column: global search results while the sidebar search field is
    /// engaged, otherwise the selected folder's message list (or an empty-state
    /// prompt). Extracted so `body` can hang the Settings gear on its toolbar.
    @ViewBuilder
    private var contentColumn: some View {
        if isSearching, let searchModel {
            // Global search owns the content column while the sidebar field
            // is engaged. Stable `.id` so it isn't torn down per keystroke;
            // the detail column still reads the selected message, against
            // the result's true mailbox via `crossFolderDetail`.
            MessageListView(
                scope: .search,
                injectedSearchModel: searchModel,
                selection: $selectedEnvelope,
                addressFilter: nil,
                onClearAddressFilter: {},
                onSearchResultSelected: { sourceFolderPath in
                    crossFolderDetail = sourceFolderPath.map { Folder(path: $0) }
                },
                onSelectionCountChanged: { listSelectionCount = $0 }
            )
            .id("search")
        } else if let selectedFolder {
            MessageListView(
                scope: .folder(selectedFolder),
                selection: $selectedEnvelope,
                addressFilter: selectedAddress?.address,
                onClearAddressFilter: { selectedAddress = nil },
                onSearchResultSelected: { sourceFolderPath in
                    crossFolderDetail = sourceFolderPath.map { Folder(path: $0) }
                },
                onSelectionCountChanged: { listSelectionCount = $0 }
            )
            .id(selectedFolder.path)
        } else {
            ContentUnavailableView(
                "Select a folder",
                systemImage: "sidebar.left",
                description: Text("Pick a mailbox from the sidebar to browse messages.")
            )
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            sidebar
        } content: {
            // Pin the list column to its persisted width and hang the drag
            // handle on its trailing edge (wide iPad/visionOS only); compact and
            // macOS pass through untouched. See `resizableContentColumn`.
            resizableContentColumn(decoratedContentColumn)
        } detail: {
            if listSelectionCount >= 2 {
                // Multi-selection: no single message to read, so mirror Mail's
                // "N Messages Selected" pane. Bulk actions live in the action
                // bar beneath the message list.
                ContentUnavailableView(
                    "\(listSelectionCount) Messages Selected",
                    systemImage: "envelope.badge",
                    description: Text("Use the action bar below the list to act on them together.")
                )
                #if os(macOS)
                .toolbar { emptyDetailToolbar }
                #endif
            } else if let folder = detailFolder, let selectedEnvelope {
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
        // Force the iPad split view to OVERLAY the sidebar rather than tile it,
        // so revealing folders floats over the message list instead of pushing
        // the list off the leading edge (which would re-break the leading swipe).
        // Best-effort and harmless if the split controller isn't found.
        #if os(iOS)
        .background(SplitOverlayConfigurator())
        #endif
        // Track the split view's overall width so the list column's max can be
        // clamped to leave the reading pane a floor (see `listColumnMaxWidth`).
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            splitWidth = newWidth
        }
        // Clearing the envelope selection AND any active address filter when
        // the folder changes keeps the detail column from briefly rendering
        // an old message against the new mailbox, and matches the plan's
        // "switching folders clears the filter" rule.
        .onChange(of: selectedFolder) { _, folder in
            selectedEnvelope = nil
            selectedAddress = nil
            crossFolderDetail = nil
            listSelectionCount = 0
            // Picking a folder shows its list on compact (it's pushed natively
            // from the sidebar List, but keep the binding in step).
            compactColumn = folder == nil ? .sidebar : .content
            #if !os(macOS)
            // On iPad-regular, re-collapse the overlaid sidebar after a folder
            // pick so the message list is the leftmost tile again and its
            // leading swipe stays live. No-op on compact (visibility ignored)
            // and already-collapsed launches (INBOX auto-select).
            if folder != nil { columnVisibility = .doubleColumn }
            #endif
            // Record the folder move for the cross-client cursor (highest-
            // priority field). Fires on user navigation and on restore alike;
            // the coordinator debounces and de-dupes writes.
            if let path = folder?.path {
                appState.navCoordinator?.recordFolder(path)
            }
        }
        // Compact navigation: a selected message pushes the reader; navigating
        // back out (the binding falls off `.detail`) clears the selection so
        // the same row can be reopened. No-ops on regular width / iPad.
        .onChange(of: selectedEnvelope) { _, envelope in
            if envelope != nil { compactColumn = .detail }
            // Record the open message (or its absence) for the cursor. Skipped
            // while searching — the search surface has no single folder to
            // anchor the cursor to.
            if !isSearching, let folderPath = selectedFolder?.path {
                if let envelope {
                    appState.navCoordinator?.recordMessage(
                        folderPath: folderPath,
                        uid: envelope.uid,
                        messageID: envelope.messageId
                    )
                } else {
                    appState.navCoordinator?.recordNoMessage(folderPath: folderPath)
                }
            }
        }
        .onChange(of: compactColumn) { _, column in
            if column != .detail, selectedEnvelope != nil { selectedEnvelope = nil }
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
        .dropDestination(for: MessageDragPayload.self) { _, _ in
            appState.endMessageDrag()
            return false
        }
        // Returning to the foreground after the initial launch: if another
        // client moved the cursor on, offer the jump. `hasLoadedInitial` gates
        // out the cold-launch path (which offers its own resume toast via the
        // sidebar's onFoldersLoaded), and `old != .active` ignores in-app
        // interruptions that didn't actually background us.
        .onChange(of: scenePhase) { old, new in
            guard new == .active, old != .active,
                  let coordinator = appState.navCoordinator,
                  coordinator.hasLoadedInitial else { return }
            Task {
                if let cursor = await coordinator.foreignCursorOnForeground() {
                    appState.showToast(
                        .resumeNavigation(folderName: Folder(path: cursor.folder).name, cursor: cursor),
                        duration: 10
                    )
                }
            }
        }
        // The resume toast was tapped: navigate to the cross-client cursor.
        // Selecting a new folder re-mounts its list (which consumes the
        // scheduled restore); a same-folder jump relies on the list observing
        // the new `pendingRestore`.
        .onChange(of: appState.navCoordinator?.navigateRequest) { _, request in
            guard let request, let coordinator = appState.navCoordinator else { return }
            coordinator.navigateRequest = nil
            coordinator.scheduleRestore(for: request)
            if selectedFolder?.path != request.folder {
                selectedFolder = Folder(path: request.folder)
            }
        }
        .task {
            if searchModel == nil, let client = appState.client {
                searchModel = MessageListViewModel(
                    scope: .search,
                    client: client,
                    preferences: preferences,
                    appState: appState
                )
            }
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
}

// MARK: - Sidebar chrome

// Lifted into a same-file extension so the primary struct body stays under
// SwiftLint's `type_body_length` cap, matching the pattern used by
// `MessageListView` and its `+Filter` / `+Search` siblings.
extension MailRootView {
    /// First-load folder selection: always land on INBOX, then — in the
    /// background — check whether the saved cursor is still a usable resume
    /// target (folder present, recorded message still in the folder's initial
    /// window) and, if so, offer a "pick up where you left off" toast rather
    /// than jumping there. Tapping it drives the same `navigateRequest` path as
    /// the cross-client resume. The INBOX landing's own cursor write is held
    /// back (`armProvisionalLanding`) so a still-valid saved position survives
    /// until the user resumes or navigates on their own; if there's nothing to
    /// resume, INBOX is recorded normally once the probe returns.
    private func landOnInboxAndOfferResume(from folders: [Folder]) {
        let inbox = folders.first { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        } ?? folders.first
        appState.navCoordinator?.armProvisionalLanding()
        selectedFolder = inbox
        Task {
            let candidate = await appState.navCoordinator?.launchResumeCandidate(folders: folders)
            // If the user already navigated off INBOX while the probe ran, leave
            // them be rather than surfacing a now-stale prompt.
            guard selectedFolder?.path == inbox?.path else { return }
            if let candidate {
                appState.showToast(
                    .resumeNavigation(folderName: Folder(path: candidate.folder).name, cursor: candidate),
                    duration: 10
                )
            } else if let inbox {
                // Nothing to resume: materialize the INBOX landing we suppressed.
                appState.navCoordinator?.recordFolder(inbox.path)
            }
        }
    }

    /// Sidebar search field — the wide-layout entry to global search. Engaging
    /// it (focus, a query, or an active search) swaps the content column to
    /// cross-folder results; clearing and unfocusing it returns to the folder.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all mail", text: searchQueryBinding)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onSubmit {
                    Task { await searchModel?.runSearch() }
                }
            if !(searchModel?.searchQuery.isEmpty ?? true) {
                Button {
                    // Zeroing the query lets the mounted search list's
                    // `onChange(of: searchQuery)` drop search mode; dropping
                    // focus then swaps the content column back to the folder.
                    searchModel?.searchQuery = ""
                    searchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.12))
        )
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
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

            // The wide layout's per-context filter — and the New / Reload buttons
            // that flank it — render inside the active list view's own header
            // (`SidebarListHeaderRow`), below these tabs. Compact lets each list
            // keep its own top-of-sidebar `.searchable` and toolbar buttons.
            switch effectiveSidebarTab {
            case .folders:
                FolderListView(
                    selection: $selectedFolder,
                    externalFilter: isWideSidebar ? $folderListFilter : nil,
                    onFoldersLoaded: { folders in
                        // First load: land on INBOX and, if a saved position is
                        // still reachable, offer a resume toast (see
                        // `landOnInboxAndOfferResume`). The Compose button lives
                        // on the message-list toolbar, so a nil-selection state
                        // would leave the user no way to start a new message;
                        // INBOX is always present
                        // (`FolderListViewModel.sortForSidebar` pins it first).
                        guard selectedFolder == nil else { return }
                        landOnInboxAndOfferResume(from: folders)
                    }
                )
            case .addresses:
                AddressListView(
                    selection: $selectedAddress,
                    externalFilter: isWideSidebar ? $addressListFilter : nil
                )
            }
        }
    }

}

#if os(iOS)
// MARK: - Split overlay behavior

/// Forces the enclosing `UISplitViewController` to OVERLAY its sidebar instead
/// of tiling it. SwiftUI's `NavigationSplitView` exposes no native knob for
/// split behavior, and on a wide iPad it tiles by default — which, when the
/// folder sidebar is revealed, pushes the message list off the leading edge and
/// re-breaks the list's leading swipe. Overlaying floats the sidebar above the
/// list, so revealing folders never disturbs the list's swipe geometry.
///
/// Best-effort: it walks the parent controller chain for the split controller
/// and no-ops if none is found (the sidebar then re-tiles on reveal, which is
/// still functional). Re-applied on every `updateUIViewController` so it
/// survives the layout passes that can reset `preferredSplitBehavior`.
private struct SplitOverlayConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Proxy { Proxy() }
    func updateUIViewController(_ proxy: Proxy, context: Context) { proxy.applyOverlayBehavior() }

    final class Proxy: UIViewController {
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyOverlayBehavior()
        }

        func applyOverlayBehavior() {
            var ancestor: UIViewController? = parent
            while let current = ancestor {
                if let split = current as? UISplitViewController {
                    split.preferredSplitBehavior = .overlay
                    return
                }
                ancestor = current.parent
            }
        }
    }
}
#endif

// MARK: - Resizable list column

/// Clamp bounds for the resizable message-list column on the wide iPad layout.
private let listColumnMinWidth: CGFloat = 300
/// Width reserved for the reading pane when clamping the list column's maximum.
private let readerColumnMinWidth: CGFloat = 360

extension MailRootView {
    /// Whether the list column is pinned to a user-set width and shows the drag
    /// handle. True only on the wide regular-width iPad / visionOS layout:
    /// compact collapses to a stack (a fixed width would fight the collapse) and
    /// macOS already resizes and persists its dividers natively.
    private var resizableColumns: Bool {
        #if os(macOS)
        return false
        #else
        return showsSettingsGear
        #endif
    }

    /// Upper bound for the list column: whatever leaves the reading pane its
    /// floor. Falls back to a generous cap until the first geometry read lands.
    private var listColumnMaxWidth: CGFloat {
        guard splitWidth > 0 else { return 640 }
        return max(listColumnMinWidth, splitWidth - readerColumnMinWidth)
    }

    /// The persisted list-column width, clamped to the current valid range.
    private var listColumnWidth: CGFloat {
        min(max(CGFloat(listColumnWidthStored), listColumnMinWidth), listColumnMaxWidth)
    }

    /// Binding the drag handle writes: clamps on read, persists on write.
    private var listColumnWidthBinding: Binding<CGFloat> {
        Binding(
            get: { listColumnWidth },
            set: { listColumnWidthStored = Double($0) }
        )
    }

    /// The content column plus its iPad Settings gear, before any width pinning.
    /// Extracted from `body` so the gear's `#if`-guarded toolbar can be wrapped
    /// by `resizableContentColumn` as a single view.
    @ViewBuilder
    fileprivate var decoratedContentColumn: some View {
        contentColumn
            // App-level Settings gear, relocated next to the content column's
            // sidebar toggle now that the sidebar — its former home — starts
            // collapsed on iPad. Regular-width iPad only (compact keeps its
            // Settings tab, macOS its Settings scene), matching where the gear
            // appeared before.
            #if !os(macOS)
            .toolbar {
                if showsSettingsGear {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            appState.requestSettings()
                        } label: {
                            Image(systemName: "gearshape")
                                .accessibilityLabel("Settings")
                        }
                    }
                }
            }
            #endif
    }

    /// Pins the content column to the persisted width and overlays the drag
    /// handle, but only on the wide iPad/visionOS layout. Compact (collapsed
    /// stack) and macOS (native resizable dividers) pass the column through
    /// untouched.
    @ViewBuilder
    fileprivate func resizableContentColumn(_ column: some View) -> some View {
        if resizableColumns {
            column
                .navigationSplitViewColumnWidth(listColumnWidth)
                .overlay(alignment: .trailing) {
                    ColumnResizeHandle(
                        width: listColumnWidthBinding,
                        minWidth: listColumnMinWidth,
                        maxWidth: listColumnMaxWidth
                    )
                }
        } else {
            column
        }
    }
}
