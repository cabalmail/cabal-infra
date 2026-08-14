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
struct MailRootView: View {
    @State private var selectedFolder: Folder?
    @State private var selectedEnvelope: Envelope?
    /// Whether the launch `.task` has already landed on the provisional
    /// INBOX (see there). Never reset — a later re-appearance with a
    /// deliberately cleared selection must not yank the user back to INBOX.
    @State private var didProvisionalLand = false
    /// Set alongside the provisional landing and consumed by the sidebar's
    /// first `onFoldersLoaded`, which swaps the fetched INBOX into the
    /// selection and probes the resume cursor (`finishInboxLanding`).
    @State private var awaitingLaunchReconcile = false
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
    /// Wide-layout sidebar visibility. iOS pins this COLLAPSED (`.doubleColumn`,
    /// via the constant `splitVisibility` binding): on regular-width iPad the
    /// folder sidebar never tiles into the split — revealing folders floats
    /// `folderPanelOverlay` OVER the message list instead, so the list never
    /// moves and its leading swipe (read/unread) keeps its normal drag
    /// distance. (When the sidebar tiled to the list's left,
    /// `twoBesideSecondary`, the split view's interactive column gesture
    /// out-arbitrated the row's leading swipe; and UIKit's `.overlay` split
    /// behavior still composes the sidebar BESIDE the supplementary column, so
    /// it, too, would shove the list rightward.) macOS keeps the sidebar
    /// visible (`.all`): a NavigationSplitView there is AppKit-backed with no
    /// gesture conflict, and it's a desktop multi-pane window. Ignored on
    /// compact iPhone (navigates via `compactColumn`).
    #if os(macOS)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    #endif
    private var splitVisibility: Binding<NavigationSplitViewVisibility> {
        #if os(macOS)
        $columnVisibility
        #else
        .constant(.doubleColumn)
        #endif
    }
    #if os(iOS)
    /// Whether the floating folder panel is showing (regular-width iPad only).
    /// The panel replaces the split view's own sidebar reveal — see
    /// `folderPanelOverlay`. Starts hidden every launch, like the collapsed
    /// sidebar it replaced.
    @State private var folderPanelPresented = false
    #endif
    /// Whether the right-hand addresses inspector is showing. Hidden by default
    /// (on every launch) — it's an occasional reference/management panel reached
    /// from the toolbar, so it doesn't persist open. Wide layouts only; compact
    /// iPhone reaches addresses through its own bottom tab, never this inspector.
    @State private var addressInspectorPresented = false
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
    /// Live width of the content (message list) column, read the same way. The
    /// toolbar search field is sized against it — a toolbar item is laid out
    /// outside its column's clip, so an item wider than the column overhangs
    /// into the neighbouring one instead of being cut.
    @State private var contentColumnWidth: CGFloat = 0
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    /// Drives the cross-client cursor reconcile: returning to the foreground
    /// re-reads the server cursor and, if another client moved it on, offers
    /// the "pick up where you left off" toast. The initial launch transition
    /// doesn't fire `.onChange`, so a cold launch offers its own resume toast
    /// from the folder-load path (`landOnInboxAndOfferResume`) instead.
    @Environment(\.scenePhase) private var scenePhase
    /// Global-search model for the wide (iPad-regular / macOS) layout, owned
    /// here so the toolbar search field and the content column share one query
    /// and result set. The compact-width analogue is `SearchView` (the iPhone
    /// `Tab(role: .search)`); there's no bottom tab bar here, so search is
    /// reached from the message-list column's toolbar instead.
    @State private var searchModel: MessageListViewModel?
    /// Focus on the global search field. Drives the content-column swap: while
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
    /// Folder that drives `MessageDetailView`. Cross-folder search results
    /// override the sidebar selection; everything else uses it directly.
    private var detailFolder: Folder? {
        crossFolderDetail ?? selectedFolder
    }

    /// Whether the content column should show search results rather than the
    /// selected folder: the search field is focused, holds a query, or a
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

    /// Content column: global search results while the search field is
    /// engaged, otherwise the selected folder's message list (or an empty-state
    /// prompt). Extracted so `body` can hang the Settings gear on its toolbar.
    @ViewBuilder
    private var contentColumn: some View {
        if isSearching, let searchModel {
            // Global search owns the content column while the search field
            // is engaged. Stable `.id` so it isn't torn down per keystroke;
            // the detail column still reads the selected message, against
            // the result's true mailbox via `crossFolderDetail`.
            MessageListView(
                scope: .search,
                injectedSearchModel: searchModel,
                selection: $selectedEnvelope,
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
                description: Text("Pick a folder from the sidebar to browse messages.")
            )
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: splitVisibility, preferredCompactColumn: $compactColumn) {
            #if os(iOS)
            if isWideSidebar {
                // Regular-width iPad: the folder list lives in the floating
                // panel (`folderPanelOverlay`), not in this column, which stays
                // empty and permanently collapsed. Removing the system sidebar
                // toggle keeps the content toolbar from offering to reveal the
                // empty column — the custom button in `decoratedContentColumn`
                // drives the panel instead. The zero column width matters:
                // `splitVisibility`'s pinned `.doubleColumn` only holds until
                // a rotation or window resize, when UIKit's split controller
                // re-expands the sidebar on its own and the constant binding
                // can't push back — tiling this column in as a blank leading
                // pane. At width 0 the re-expanded column has no footprint,
                // so the pane can never appear.
                Color.clear
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(0)
            } else {
                sidebar
            }
            #else
            // macOS opens the sidebar at a readable width and remembers the
            // one the user drags to; every other platform passes through.
            sidebar.sidebarColumnWidthPolicy()
            #endif
        } content: {
            // Pin the list column to its persisted width and hang the drag
            // handle on its trailing edge (wide iPad/visionOS only); compact and
            // macOS pass through untouched. See `resizableContentColumn`.
            resizableContentColumn(decoratedContentColumn)
        } detail: {
            detailColumn
        }
        // Revealing folders floats a panel OVER the message list rather than
        // tiling the split's sidebar column, so the list never shifts and its
        // leading swipe geometry is undisturbed. Regular-width iPad only —
        // compact iPhone navigates the folder list as the stack root.
        // The explicit `.leading` alignment matters: while the panel is closed
        // the scrim is absent, the ZStack shrinks to the panel's own size, and
        // a default (centered) overlay would park the slid-out panel half on
        // screen instead of fully off the leading edge.
        #if os(iOS)
        .overlay(alignment: .leading) {
            if isWideSidebar { folderPanelOverlay }
        }
        #endif
        // Keep the Message menu's commands validated against what they'd
        // actually act on (see `MessageMenuAvailability`).
        .reportsMessageMenuAvailability(
            selectedCount: listSelectionCount,
            hasOpenMessage: selectedEnvelope != nil
        )
        // Track the split view's overall width so the list column's max can be
        // clamped to leave the reading pane a floor (see `listColumnMaxWidth`).
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            splitWidth = newWidth
        }
        // Clearing the envelope selection when the folder changes keeps the
        // detail column from briefly rendering an old message against the
        // new mailbox.
        .onChange(of: selectedFolder) { old, folder in
            // A same-path change is a metadata reconcile — the launch landing
            // swapping its provisional `Folder(path: "INBOX")` for the fetched
            // one (`finishInboxLanding`). Same mailbox, so keep the user's
            // message selection and don't re-record the cursor.
            guard old?.path != folder?.path else { return }
            selectedEnvelope = nil
            crossFolderDetail = nil
            listSelectionCount = 0
            // Picking a folder shows its list on compact (it's pushed natively
            // from the sidebar List, but keep the binding in step).
            compactColumn = folder == nil ? .sidebar : .content
            #if os(iOS)
            // On iPad-regular, slide the folder panel away after a pick so the
            // message list is fully interactive again. No-op on compact (the
            // panel is never presented there) and on launches (INBOX
            // auto-select happens with the panel already closed).
            if folder != nil {
                withAnimation(folderPanelAnimation) { folderPanelPresented = false }
            }
            #endif
            // Record the folder move for the cross-client cursor (highest-
            // priority field). Fires on user navigation and on restore alike;
            // the coordinator debounces and de-dupes writes.
            if let path = folder?.path {
                appState.navCoordinator?.recordFolder(path)
            }
        }
        // Compact navigation: a selected message pushes the reader, and losing
        // the selection while the reader is up pops back to the list (see
        // `CompactColumnPolicy`); navigating back out by hand (the binding
        // falls off `.detail`) clears the selection so the same row can be
        // reopened. No-ops on regular width / iPad.
        .onChange(of: selectedEnvelope) { _, envelope in
            compactColumn = CompactColumnPolicy.column(hasSelectedMessage: envelope != nil, current: compactColumn)
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
            // A navigate request can be parked before this view exists —
            // cold launch from a tapped push notification routes as soon as
            // the session is wired, which precedes the first render, so the
            // `.onChange` above never fires for it. Draining it here also
            // pre-empts the provisional INBOX landing below (and with it
            // the sidebar's launch reconcile).
            if let coordinator = appState.navCoordinator,
               let request = coordinator.navigateRequest {
                coordinator.navigateRequest = nil
                coordinator.scheduleRestore(for: request)
                if selectedFolder?.path != request.folder {
                    selectedFolder = Folder(path: request.folder)
                }
            }
            // Land on a provisional INBOX immediately — before the folder
            // list returns — so the message list (and its on-disk envelope
            // cache) starts loading without waiting on `/list_folders`. The
            // message machinery only needs the path; the sidebar's first
            // `onFoldersLoaded` swaps in the fetched folder and probes the
            // resume cursor (`finishInboxLanding`). Seeded as subscribed so
            // the list doesn't flash the unsubscribed-folder banner before
            // the real subscription state arrives; gated on a wired client
            // because the list's one-shot `.task` can't create its model
            // without one. INBOX itself is guaranteed to exist (RFC 3501).
            if !didProvisionalLand, selectedFolder == nil, appState.client != nil {
                didProvisionalLand = true
                awaitingLaunchReconcile = true
                appState.navCoordinator?.armProvisionalLanding()
                selectedFolder = Folder(path: "INBOX", isSubscribed: true)
            }
            if searchModel == nil, let client = appState.client {
                searchModel = MessageListViewModel(
                    scope: .search,
                    client: client,
                    preferences: preferences,
                    appState: appState
                )
            }
        }
        // Addresses live in a trailing panel rather than the left sidebar,
        // keeping the sidebar free for folders (and, later, feeds). Hidden by
        // default; the toolbar `at` button (wide layouts) toggles it. Tapping
        // an address copies it to the pasteboard.
        // `.inspector` is the native trailing sidebar on iOS/macOS; visionOS
        // lacks it, so the same toggle drives a sheet there instead.
        #if os(visionOS)
        .sheet(isPresented: $addressInspectorPresented) {
            AddressListView(externalFilter: $addressListFilter)
                .environment(appState)
        }
        #else
        .inspector(isPresented: $addressInspectorPresented) {
            AddressListView(externalFilter: $addressListFilter)
                .addressInspectorWidth()
        }
        #endif
    }

    // The macOS empty reading pane reserves its toolbar slots with
    // `EmptyDetailToolbar` (its own file), which derives the stand-in set
    // from the same `ReaderToolbarLayout.macToolbar` order the real toolbar
    // draws.
}

// MARK: - Sidebar chrome

// Lifted into a same-file extension so the primary struct body stays under
// SwiftLint's `type_body_length` cap, matching the pattern used by
// `MessageListView` and its `+Filter` / `+Search` siblings.
extension MailRootView {
    /// Completes the launch INBOX landing once the folder list arrives. The
    /// launch `.task` has usually already selected a provisional
    /// `Folder(path: "INBOX")` so the message list didn't wait on
    /// `/list_folders`; here the fetched INBOX is swapped into the selection —
    /// `Folder` equality spans attributes/subscription, and the sidebar's row
    /// highlight only matches once the tag values agree. Same path, so the
    /// mounted list (`.id(selectedFolder.path)`) survives untouched and the
    /// same-path guard on `.onChange` keeps the swap from clearing state.
    /// Then — in the background — check whether the saved cursor is still a
    /// usable resume target (folder present, recorded message still in the
    /// folder's initial window) and, if so, offer a "pick up where you left
    /// off" toast rather than jumping there. Tapping it drives the same
    /// `navigateRequest` path as the cross-client resume. The INBOX landing's
    /// own cursor write is held back (`armProvisionalLanding`) so a
    /// still-valid saved position survives until the user resumes or navigates
    /// on their own; if there's nothing to resume, INBOX is recorded normally
    /// once the probe returns.
    private func finishInboxLanding(from folders: [Folder]) {
        let inbox = folders.first { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        } ?? folders.first
        if let current = selectedFolder {
            // Provisional landing already on screen. If a navigate request
            // (push-notification launch) has moved the selection elsewhere,
            // leave it be — the probe below still runs but its post-guard
            // keeps it silent.
            if current.path.caseInsensitiveCompare("INBOX") == .orderedSame, let inbox { selectedFolder = inbox }
        } else {
            // The client wasn't wired when the launch task ran, so there was
            // no provisional landing: land now, as before.
            appState.navCoordinator?.armProvisionalLanding()
            selectedFolder = inbox
        }
        Task {
            let candidate = await appState.navCoordinator?.launchResumeCandidate(folders: folders)
            // If the user already navigated off INBOX while the probe ran, leave
            // them be rather than surfacing a now-stale prompt.
            guard let inbox, selectedFolder?.path == inbox.path else { return }
            if let candidate {
                appState.showToast(
                    .resumeNavigation(folderName: Folder(path: candidate.folder).name, cursor: candidate),
                    duration: 10
                )
            } else {
                // Nothing to resume: materialize the INBOX landing we suppressed.
                appState.navCoordinator?.recordFolder(inbox.path)
            }
        }
    }

    /// Detail column content: the reader for the selected message, a
    /// multi-selection placeholder, or an empty-state prompt.
    ///
    /// The global search field used to right-align in this column's toolbar;
    /// the #1047 toolbar rework moved it above the message list
    /// (`decoratedContentColumn`) — the results it drives appear in that
    /// column, and the reader needs its whole toolbar section for the eleven
    /// action buttons.
    @ViewBuilder
    private var detailColumn: some View {
        Group {
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
                .toolbar { EmptyDetailToolbar() }
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
                .toolbar { EmptyDetailToolbar() }
                #endif
            }
        }
    }

    /// The search field itself — magnifying-glass icon, the query text field,
    /// and a clear button — on a rounded translucent background. The wide
    /// (iPad-regular / macOS) toolbar host (`toolbarSearchField`) adds its own
    /// outer layout; compact iPhone has no sidebar search field (it uses the
    /// bottom Search tab), so this is the only remaining host.
    @ViewBuilder
    private var searchFieldCore: some View {
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
    }

    /// Toolbar host for the search field (wide iPad-regular / macOS): a stated
    /// width so it right-aligns cleanly above the message-list column rather
    /// than stretching, capped to the column — less its fixed sibling
    /// buttons — so it can't overhang into the neighbouring one
    /// (`ToolbarSearchFieldWidth`). Same query/focus wiring as
    /// the sidebar host.
    @ViewBuilder
    private var toolbarSearchField: some View {
        searchFieldCore
            .frame(width: ToolbarSearchFieldWidth.width(
                columnWidth: contentColumnWidth,
                inspectorPresented: addressInspectorPresented
            ))
    }

    @ViewBuilder
    private var sidebar: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            // Brand mark at the top of the sidebar, below the traffic-light /
            // toolbar row and above the search field. macOS never displaced a
            // title here (the sidebar column never showed one); the mark is
            // purely additive. iOS/iPadOS host theirs in the toolbar below.
            HStack {
                CabalmailMark(size: 90)
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.top, 12)
            #endif

            // Global search lives in the detail column's toolbar on wide layouts
            // (iPad-regular / macOS; see `detailColumn`) and in the dedicated
            // Search tab on compact iPhone (`SignedInRootView`'s
            // `Tab(role: .search)`). The sidebar carries no search field of its
            // own — one above the folder list would be redundant with the Search
            // tab on compact.

            // Folders own the sidebar; addresses moved to the trailing inspector
            // (see `.inspector` in `body`). The wide layout's per-context filter —
            // and the New / Reload buttons that flank it — render inside the list
            // view's own header (`SidebarListHeaderRow`). Compact lets the list
            // keep its own top-of-sidebar `.searchable` and toolbar buttons.
            FolderListView(
                selection: $selectedFolder,
                externalFilter: isWideSidebar ? $folderListFilter : nil,
                onFoldersLoaded: { folders in
                    // First load: swap the fetched INBOX into the launch
                    // task's provisional landing and, if a saved position is
                    // still reachable, offer a resume toast (see
                    // `finishInboxLanding`). Guarded so a later re-fire (the
                    // sidebar remounts on an iPad layout swap) can't re-seed
                    // the selection out from under the user; the nil check
                    // covers a launch whose client wasn't wired in time for
                    // the provisional landing.
                    guard awaitingLaunchReconcile || selectedFolder == nil else { return }
                    awaitingLaunchReconcile = false
                    finishInboxLanding(from: folders)
                }
            )
        }
        // Sidebar branding (see `SidebarBranding.swift`): the wash paints this
        // column only — the entire folder screen on compact iPhone, where
        // this column IS the screen; the floating sidebar on iPad; the sidebar
        // material on macOS. Hiding the list's scroll background (inherited by
        // the folder `List` below) lets the wash show through the native
        // material instead of being painted over by the system background.
        .scrollContentBackground(.hidden)
        .background { SidebarWash().ignoresSafeArea() }
        #if !os(macOS)
        // The Cabalmail mark stands in for the sidebar's "Folders" title:
        // inline display mode suppresses the large title, the clear principal
        // item suppresses the inline text, and `FolderListView`'s
        // `.navigationTitle("Folders")` string stays for VoiceOver and the
        // back button. The mark itself rides the leading toolbar slot — the
        // system sidebar toggle and the compact New / Reload buttons keep
        // their own slots.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1)
            }
            // On OS 26's liquid glass, a bare toolbar item gets wrapped in a
            // glass capsule, which makes the decorative mark read as a button.
            // Detach it from the shared glass background where the API exists;
            // earlier systems render toolbar images plain anyway. The SDK
            // marks `sharedBackgroundVisibility` explicitly unavailable on
            // visionOS (a runtime `#available` check can't gate a symbol the
            // compiler rejects), so the visionOS build takes the plain path.
            #if os(visionOS)
            ToolbarItem(placement: .topBarLeading) {
                CabalmailMark(size: isWideSidebar ? 102 : 132)
            }
            #else
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) {
                    CabalmailMark(size: isWideSidebar ? 102 : 132)
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) {
                    CabalmailMark(size: isWideSidebar ? 102 : 132)
                }
            }
            #endif
        }
        #endif
    }

}

#if os(iOS)
// MARK: - Floating folder panel

/// The floating folder panel that replaces the split view's own sidebar reveal
/// on regular-width iPad.
///
/// SwiftUI's `NavigationSplitView` exposes no knob that reveals the sidebar
/// over an unmoving content column: tiling and displacing both shove the
/// message list rightward, and even UIKit's `.overlay` split behavior (the
/// previous attempt here, `SplitOverlayConfigurator`) composes the sidebar
/// BESIDE the supplementary column over the detail — the list still moves. So
/// the split's sidebar column is pinned collapsed and the folder list floats
/// here instead: a fixed-width panel slid in from the leading edge over the
/// list, with a dimming scrim that dismisses on tap.
///
/// The panel stays MOUNTED while closed (slid offscreen, not removed) so
/// `FolderListView` loads folders at launch and drives the INBOX landing /
/// resume toast (`onFoldersLoaded`) exactly as the hidden sidebar column used
/// to — and so its drop targets are live the moment the panel opens mid-drag.
extension MailRootView {
    /// Slide/scrim animation, shared by the toolbar toggle and the
    /// folder-pick auto-dismiss so every path moves the panel the same way.
    var folderPanelAnimation: Animation { .snappy(duration: 0.28) }

    /// Fixed panel width, matching the split view's own sidebar column.
    private var folderPanelWidth: CGFloat { 320 }

    @ViewBuilder
    var folderPanelOverlay: some View {
        ZStack(alignment: .leading) {
            if folderPanelPresented {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(folderPanelAnimation) { folderPanelPresented = false }
                    }
                    .transition(.opacity)
                    .accessibilityLabel("Dismiss folder list")
                    .accessibilityAddTraits(.isButton)
            }
            // Its own NavigationStack: the sidebar builder hangs toolbar items
            // (the Cabalmail mark) and a navigation title, which need a
            // navigation container now that the view no longer lives in the
            // split's sidebar column.
            NavigationStack { sidebar }
                .frame(width: folderPanelWidth)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.25), radius: 18, x: 4, y: 0)
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .offset(x: folderPanelPresented ? 0 : -(folderPanelWidth + 60))
                .accessibilityHidden(!folderPanelPresented)
        }
        .animation(folderPanelAnimation, value: folderPanelPresented)
    }
}
#endif

// MARK: - Resizable list column

/// Clamp bounds for the resizable message-list column on the wide iPad layout.
/// Shared with the macOS width policy so the two can't drift — see
/// `ListColumnWidth`.
private let listColumnMinWidth = ListColumnWidth.minimum
/// Width reserved for the reading pane when clamping the list column's maximum.
private let readerColumnMinWidth = ListColumnWidth.readerFloor

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
            // The search field sizes itself against this column (see
            // `ToolbarSearchFieldWidth`); a toolbar item can't measure its own
            // pane, so the pane measures itself here.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                contentColumnWidth = newWidth
            }
            // Global search rides the message-list column's toolbar on wide
            // layouts (moved from above the reading pane in the #1047 toolbar
            // rework — the results it drives show in this column, and the
            // reader needs its toolbar section for its own buttons), next to
            // the toggle for the trailing addresses inspector. Wide layouts
            // only (macOS always; regular-width iPad via `showsSettingsGear`);
            // compact iPhone reaches search through its dedicated tab and
            // addresses through its bottom tab instead.
            .toolbar {
                if isWideSidebar {
                    ToolbarItem(placement: .primaryAction) {
                        toolbarSearchField
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            addressInspectorPresented.toggle()
                        } label: {
                            Image(systemName: "at")
                                .accessibilityLabel("Addresses")
                        }
                    }
                }
            }
            // Folder-panel toggle (standing in for the removed system sidebar
            // toggle, same leading slot) and the app-level Settings gear.
            // Regular-width iPad only (compact keeps its Settings tab and
            // navigates folders as the stack root; macOS has its Settings
            // scene and a tiled sidebar).
            #if os(iOS)
            .toolbar {
                if showsSettingsGear {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            withAnimation(folderPanelAnimation) {
                                folderPanelPresented.toggle()
                            }
                        } label: {
                            Image(systemName: "sidebar.leading")
                                .accessibilityLabel("Toggle folder list")
                        }
                    }
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
    /// handle, but only on the wide iPad/visionOS layout. macOS keeps its
    /// native resizable dividers and instead bounds the column so the reading
    /// pane can't be starved (`ListColumnWidth`); compact iPhone, where that
    /// policy passes through, gets the column untouched.
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
            column.listColumnWidthPolicy(splitWidth: splitWidth)
        }
    }
}
