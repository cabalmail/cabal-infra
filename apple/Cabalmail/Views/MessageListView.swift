import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

/// Envelope list for a single folder. Selection is lifted to the parent so
/// the split view can bind the detail pane to it.
struct MessageListView: View {
    /// What this list shows — a folder or the global search surface. Drives the
    /// title, the top-inset chrome (filter pills vs. search-result banner), and
    /// whether the folder lifecycle (initial load / IDLE / 60s poll) runs.
    let scope: MessageListScope
    /// Parent-owned view model for `.search` scope (so the search input —
    /// `.searchable` on iPhone, the sidebar field on iPad/macOS — can bind the
    /// same model). Nil in folder scope: the view self-creates the folder model
    /// in `.task` and owns its full lifecycle.
    var injectedSearchModel: MessageListViewModel?
    /// Resolved anchor folder (a sentinel in `.search` scope). Computed so the
    /// folder-keyed extensions read it unchanged.
    var folder: Folder { scope.folder }
    /// True for the global search surface.
    var isSearchScope: Bool { scope.isSearch }
    @Binding var selection: Envelope?
    /// When set, narrows the visible envelopes to those whose `To` or `Cc`
    /// includes this address (case-insensitive substring match), matching
    /// `react/admin/src/Email/Messages/Envelopes.jsx` byte-for-byte.
    let addressFilter: String?
    /// Tapped on the filter chip to drop the address scope.
    let onClearAddressFilter: () -> Void
    /// Fires when the selected envelope is a cross-folder search result.
    /// The string is the result's source folder path — `MailRootView` uses
    /// it to build a synthetic `Folder` for `MessageDetailView` so the
    /// detail's mark-read / archive / move operations target the message's
    /// true mailbox rather than the sidebar's current selection. `nil`
    /// fires when the selection clears or returns to a same-folder row.
    let onSearchResultSelected: (String?) -> Void
    /// Reports how many messages are currently selected so the parent can show
    /// a "N messages selected" placeholder in the reading pane during a multi-
    /// selection. Fires only on wide/keyboard layouts, where the native multi-
    /// select list drives `selectedUIDs`; compact iPhone keeps the single-
    /// selection + touch edit-mode flow and never calls this.
    let onSelectionCountChanged: (Int) -> Void

    // `appState` is not private so the +Bulk sibling can reach it for
    // the move-destination sheet's `client` lookup; matches the pattern
    // used for `model` and `filtersPresented` further down.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow
    #if !os(macOS)
    // Wide vs. compact gates whether message rows are draggable. On a
    // compact iPhone the sidebar and the message list never share the
    // screen, so there's nowhere to drop a message, and a long-press drag
    // would only fight each row's context menu. Non-private so the `+Rows`
    // extension that builds the rows can read it. macOS has no size class
    // and is always treated as wide (see `isWideLayout`).
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    #endif
    // Drives the background-snapshot optimization: while the scene isn't
    // `.active`, `messageRow` (in `+Selection`) renders cheap placeholder
    // rows instead of the per-row `List` that backs the swipe actions, so
    // the system's background snapshot has no `List`s to lay out -- that
    // synchronous relayout is what could exceed the scene-update watchdog
    // after an archive-then-background. Non-private so the cross-file
    // extension can read it.
    @Environment(\.scenePhase) var scenePhase
    // `model` and `filtersPresented` are module-internal (no access
    // modifier) so the same-module extensions in `+Search` and `+macOS`
    // can read them without round-tripping through accessors.
    @State var model: MessageListViewModel?
    @State private var composeSeed: Draft?
    /// List-row height. Rows are pinned to this so the virtualized list
    /// (`+Selection`'s `virtualizedList`) can reserve the off-window rows as
    /// exact blank space: the scroll extent then reflects the whole folder, the
    /// scrollbar is true-to-size, and each row keeps its absolute position.
    ///
    /// The index-addressed virtualization needs ONE *uniform* height -- but
    /// uniform doesn't mean constant. `@ScaledMetric` scales the base value with
    /// the user's Dynamic Type setting (relative to `.subheadline`, the text
    /// style the row's two lines use), so every row and every placeholder reads
    /// the same height at any given setting -- the invariant holds -- and they
    /// all recompute together when the accessibility size changes. Without this,
    /// larger accessibility fonts overflowed the fixed height and the per-row
    /// `SwipeActionRow` List began scrolling its own clipped content, capturing
    /// the drag meant to scroll the whole list.
    ///
    /// The base 58 clears the row's two `.subheadline` lines (sender route +
    /// one-line subject) at the default size with a little slack; scaling
    /// preserves that slack proportionally. Instance (not `static`) because
    /// `@ScaledMetric` reads the environment; module-internal so the
    /// `+Selection` extension can pin rows and placeholders to it.
    @ScaledMetric(relativeTo: .subheadline) var rowHeight: CGFloat = 58
    /// Diameter of the per-row sender avatar. Fixed (not `@ScaledMetric`) so
    /// it can't grow past `rowHeight`; 32 sits comfortably within the 58pt
    /// row beside the two text lines. Shared by `MessageRow` and the
    /// `+Selection` `placeholderRow` so the real and skeleton rows keep the
    /// same leading inset.
    static let avatarSize: CGFloat = 32
    /// `true` while the filter sheet is presented over the message list.
    @State var filtersPresented = false
    /// Set by the row context menu's "Move to folder…" item; presents the
    /// MoveToFolderSheet anchored to this envelope. `Envelope` is
    /// `Identifiable` so `.sheet(item:)` reuses the same presentation
    /// machinery as composeSeed.
    @State var envelopeToMove: Envelope?
    /// Set by the delete affordances while the list shows Trash (row
    /// swipe / menu for a single message; selection menu, action bar,
    /// and Cmd+Delete for a multi-selection); presents the "Delete
    /// Forever?" confirmation for the captured UID set. Non-private so
    /// the `+Rows` / `+Bulk` / `+Actions` extensions can stage it.
    @State var purgeCandidate: PurgeCandidate?
    /// `true` while the bulk-move destination picker is presented.
    @State var bulkMoveSheetPresented = false
    /// Set by the wide-layout selection context menu's "Move to folder…"
    /// item and the Cmd+M shortcut; presents the MoveToFolderSheet for
    /// the captured UID set (see `MessageListView+Actions.swift`).
    @State var moveCandidate: SelectionMoveCandidate?
    /// `true` while the unsubscribed-folder banner's Refresh button is
    /// in flight. The banner lives in `+UnsubscribedBanner.swift`;
    /// hoisting the flag here lets the `safeAreaInset` builder see it
    /// without a separate `@State` per inset.
    @State var unsubscribedRefreshInFlight = false
    /// Focus state for the message list itself (wide/keyboard layouts). The
    /// virtualized `ScrollView` binds this so Up/Down/Cmd-A/Esc are scoped to
    /// the list -- they fire only while it holds focus, never stealing those
    /// keys from the search field. Set true when a row is clicked. Non-private
    /// so the `+Selection` extension can drive it.
    @FocusState var listFocused: Bool
    #if !os(macOS)
    /// Drives the native multi-select edit mode on wide touch layouts (iPad,
    /// visionOS): the Select button toggles it, and while active the system
    /// draws selection circles and taps toggle membership in `selectedUIDs`.
    /// Non-private so the `+Bulk` extension's `selectButton` can flip it.
    /// macOS has no `EditMode` (pointer shift/command-clicks cover multi-
    /// select), so this is compiled out there.
    @State var editMode: EditMode = .inactive
    #endif

    // `body` was a single ~200-line modifier chain; once the sheets, the
    // purge confirmation, and the signal observers were all attached,
    // Swift's type checker timed out on the one expression. Splitting it
    // into layered computed properties keeps each expression small enough
    // to check: chrome -> presentation (sheets / dialogs) -> lifecycle
    // (tasks / teardown) -> observers (the onChange cluster).
    var body: some View {
        observersLayer
    }

    /// Boolean projection of `purgeCandidate` for the confirmation
    /// dialog. Mirrors the sidebar lists' delete/revoke-dialog bindings.
    private var purgeDialogBinding: Binding<Bool> {
        Binding(
            get: { purgeCandidate != nil },
            set: { isPresented in
                if !isPresented { purgeCandidate = nil }
            }
        )
    }

    @ViewBuilder
    private func composeSheet(for seed: Draft) -> some View {
        if let client = appState.client {
            ComposeView(model: ComposeViewModel(
                seed: seed,
                client: client,
                draftStore: client.draftStore,
                preferences: preferences,
                onClose: { composeSeed = nil }
            ))
            .environment(appState)
            .environment(preferences)
        }
    }

    @ViewBuilder
    private func moveSheet(for envelope: Envelope) -> some View {
        if let client = appState.client {
            // Cross-folder search rows live in `sourceFolderByUID`; the
            // sidebar's `folder` is the search scope, not the row's true
            // mailbox. Excluding the row's actual source folder from the
            // picker is what the user expects.
            let sourcePath = model?.sourceFolder(for: envelope) ?? folder.path
            MoveToFolderSheet(
                currentFolder: Folder(path: sourcePath),
                client: client,
                onSelect: { destination in
                    envelopeToMove = nil
                    if let model {
                        Task { await model.moveTo(envelope, destination: destination.path) }
                    }
                },
                onCancel: { envelopeToMove = nil }
            )
        }
    }

    /// Hands off to the standalone compose window where the platform
    /// supports it (macOS, iPadOS, visionOS); the iPhone path keeps
    /// the existing sheet so the user doesn't lose the mailbox they
    /// were just reading.
    private func presentCompose(seed: Draft) {
        if composeOpensInWindow {
            openWindow(id: composeWindowID, value: seed)
            #if canImport(AppKit)
            // Match MessageDetailView's presentCompose: pull the new
            // compose window forward when openWindow is dispatched
            // from a menu-bar shortcut, which otherwise can land it
            // behind the main window.
            NSApp.activate(ignoringOtherApps: true)
            #endif
        } else {
            composeSeed = seed
        }
    }

    @ViewBuilder
    private func content(for model: MessageListViewModel) -> some View {
        @Bindable var model = model
        let visible = filteredEnvelopes(model.envelopes)
        Group {
            // Wide/keyboard layouts get native multiple selection (shift /
            // command-click, Cmd-A, Esc); compact iPhone keeps single
            // selection. The two list variants and their selection helpers
            // live in `MessageListView+Selection.swift`.
            if isWideLayout {
                wideList(model: model, visible: visible)
            } else {
                compactList(model: model, visible: visible)
            }
        }
        // Search input lives on the search *surface*, not the folder list:
        // `.searchable` on the iPhone search tab (driving the iOS 26 tab-bar
        // morph) and the sidebar field on iPad/macOS — both bind this model's
        // `searchQuery`. The folder list no longer carries a search bar.
        //
        // Drop search mode when the query is cleared. The search field's
        // built-in × / Cancel just zero out the binding without firing
        // `.onSubmit(of: .search)`, so without this the user would be stuck
        // with stale results and no path back short of a new query.
        .onChange(of: model.searchQuery) { _, newValue in
            guard model.isSearchActive,
                  newValue.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            Task { await model.clearSearch() }
        }
        .refreshable {
            await model.refreshFromPull()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topInset(model: model) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                // The unsubscribed-folder banner is a folder-view concern; the
                // global search surface has no single folder to subscribe to.
                if !isSearchScope, !folder.isSubscribed {
                    unsubscribedFolderBanner(model: model)
                }
                if showsBulkActionBar(model: model) { bulkActionBar(model: model) }
            }
        }
    }

    // Row rendering, the top inset (search field + filter tabs), swipe /
    // context-menu actions, the multi-select list variants, and the macOS
    // inline search field all live in same-module extension files
    // (`+Rows.swift`, `+Filter.swift`, `+Selection.swift`, `+Search.swift`,
    // `+macOS.swift`) so the primary struct body stays under SwiftLint's caps.
}

// MARK: - Body layers

// Split out of the struct body for SwiftLint's `type_body_length` cap,
// matching the sibling-extension pattern noted above. Same-file so the
// layers keep access to the view's private state and helpers.
extension MessageListView {
    /// The list itself with its navigation chrome (title + toolbar).
    private var chromeLayer: some View {
        Group {
            if let model {
                content(for: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(isSearchScope ? "Search" : folder.name)
        #if os(iOS) || os(visionOS)
        // Without this, `.searchable` + the `safeAreaInset(.top)` filter
        // tabs leave the default large-title bar in a half-collapsed
        // state on first appearance: the folder name (e.g. "INBOX") is
        // hidden until the user pulls down or scrolls up. Inline keeps
        // it pinned to the nav bar at all times, matching how the same
        // platforms treat MessageDetailView.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // Compose stays as a toolbar item — it's a primary action
            // pinned to the top edge in every Mac mail client. The list-
            // shaping controls (filter / sort / select) moved into an
            // inline action bar above the list (see `topInset` below);
            // on wide screens the right-edge toolbar placement put them
            // visually farther from the list they affect than the
            // filter tabs that sat one row higher.
            //
            // macOS: Compose + Reload share a `.primaryAction` group so
            // SwiftUI doesn't sink Reload into the trailing `>>` overflow
            // chevron when the unified window toolbar (this column +
            // MessageDetailView's seven buttons) gets crowded.
            #if os(macOS)
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    presentCompose(seed: ReplyBuilder.newDraft())
                } label: {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("New Message")
                }
                .keyboardShortcut("n", modifiers: .command)
                // Force-reload button. macOS only — iOS / iPadOS / visionOS
                // users reach the cheap merge-refresh via pull-to-refresh,
                // which is the gesture those platforms expect. Routed
                // through `requestRefresh()` so the toolbar button and the
                // Mailbox > Refresh menu item share one code path — both
                // land on `MessageListViewModel.hardReload()`, which wipes
                // in-memory state before the server fetch so the user has a
                // reliable escape from any stale-state bug the merge path
                // doesn't catch.
                Button {
                    appState.requestRefresh()
                } label: {
                    RefreshActivityIcon(isLoading: model?.isLoading == true)
                        .accessibilityLabel("Refresh")
                }
                .disabled(model == nil || model?.isLoading == true)
            }
            #else
            ToolbarItem {
                Button {
                    presentCompose(seed: ReplyBuilder.newDraft())
                } label: {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("New Message")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            #endif
        }
    }

    /// Sheets and confirmation dialogs presented over the list.
    private var presentationLayer: some View {
        chromeLayer
        .sheet(isPresented: $filtersPresented) {
            filtersSheet
        }
        .sheet(item: $composeSeed) { seed in
            composeSheet(for: seed)
        }
        .sheet(item: $envelopeToMove) { envelope in
            moveSheet(for: envelope)
        }
        .sheet(isPresented: $bulkMoveSheetPresented) {
            if let model {
                bulkMoveSheet(model: model)
            }
        }
        .sheet(item: $moveCandidate) { candidate in
            selectionMoveSheet(for: candidate)
        }
        .confirmationDialog(
            "Delete Forever?",
            isPresented: purgeDialogBinding,
            titleVisibility: .visible,
            presenting: purgeCandidate
        ) { candidate in
            Button("Delete Forever", role: .destructive) {
                purgeCandidate = nil
                if let model {
                    Task { await model.purgeMessages(uids: candidate.uids) }
                }
            }
            Button("Cancel", role: .cancel) {
                purgeCandidate = nil
            }
        } message: { candidate in
            Text(
                candidate.uids.count == 1
                ? "This message will be permanently deleted. This can't be undone."
                : "These \(candidate.uids.count) messages will be permanently deleted. This can't be undone."
            )
        }
    }

    /// Lifecycle: initial load + IDLE watcher start, the 60-second
    /// fallback refresh, and watcher teardown.
    private var lifecycleLayer: some View {
        presentationLayer
        .task {
            if model == nil, let client = appState.client {
                if isSearchScope {
                    // Parent owns the search model (its query is bound by the
                    // external search input). No folder load / IDLE here — it
                    // populates only when a search runs.
                    model = injectedSearchModel
                } else {
                    model = MessageListViewModel(
                        scope: scope,
                        client: client,
                        preferences: preferences,
                        appState: appState
                    )
                    await model?.loadInitial()
                    await model?.startWatching()
                    // Cross-client restore: if this folder is the saved
                    // cursor's target, select the remembered message now that
                    // its envelope is loaded.
                    if let model { applyPendingRestore(model: model) }
                }
            }
            // Cold-launch mailto: arrives via `.onOpenURL` in the app
            // entry, which parks the seed on AppState before this
            // view's `.onChange(of: composeRequestTick)` is in the
            // hierarchy. Drain it here so the compose surface opens
            // on first appear.
            if let seed = appState.consumePendingComposeSeed() {
                presentCompose(seed: seed)
            }
        }
        // Wall-clock fallback refresh. IDLE usually pushes new mail within
        // seconds, but long-lived IDLE sockets can stall silently (iOS
        // suspends idle connections, cellular handoffs drop the stream,
        // NAT/middleboxes time out TCP after a few minutes). Polling every
        // 60 seconds while the list is on screen guarantees the user sees
        // new mail without pull-to-refresh. `.task` cancels automatically
        // on `.onDisappear`, so the timer stops with the watcher.
        .task {
            // Folder-only fallback poll; the search surface has no folder to
            // re-STATUS and re-running the active search on a timer isn't wanted.
            guard !isSearchScope else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                await model?.refresh()
            }
        }
        .onDisappear {
            // Tear down the IDLE watcher when the folder drops off-screen.
            // The view is rebuilt (via `.id(folder.path)` in MailRootView)
            // when the user picks another folder, so `startWatching` in the
            // new instance's `.task` starts a fresh IDLE session against the
            // new mailbox.
            let model = model
            Task { await model?.stopWatching() }
        }
    }

    /// AppState signal observers: menu / shortcut ticks, detail-view
    /// dispose and flag signals, selection routing, and drag-and-drop
    /// move requests.
    private var observersLayer: some View {
        lifecycleLayer
        // macOS Commands menu (File → New Message, Mailbox → Refresh) and
        // keyboard shortcuts route through `AppState` tick counters. The
        // view lifted into view reacts by opening compose / kicking a
        // refresh. Using the currently-displayed list as the refresh target
        // matches every desktop mail client's convention.
        .onChange(of: appState.composeRequestTick) { _, _ in
            // Menu shortcuts pass nil; the mailto: URL handler parks
            // a pre-filled draft. Fall back to a fresh draft when no
            // seed accompanies the request.
            let seed = appState.consumePendingComposeSeed() ?? ReplyBuilder.newDraft()
            presentCompose(seed: seed)
        }
        .onChange(of: appState.refreshRequestTick) { _, _ in
            // Manual refresh paths (Mailbox > Refresh menu item, the
            // arrow.clockwise toolbar button) get hard-reload semantics
            // — wipe in-memory state before refresh — so the user has a
            // reliable escape from any stale-state bug the merge path
            // doesn't catch. The IDLE watcher and the 60s timer keep
            // hitting `refresh()` directly; they fire too often to be
            // discarding cached envelopes on every tick.
            Task { await model?.hardReload() }
        }
        // Message-menu chords (Cmd+T / Cmd+Shift+8 / Cmd+M) acting on the
        // current selection. Handlers live in `MessageListView+Actions.swift`;
        // each no-ops when nothing is selected.
        .onChange(of: appState.toggleSeenRequestTick) { _, _ in
            if let model { toggleSeenOnSelection(model: model) }
        }
        .onChange(of: appState.toggleFlaggedRequestTick) { _, _ in
            if let model { toggleFlaggedOnSelection(model: model) }
        }
        .onChange(of: appState.moveSelectionRequestTick) { _, _ in
            if let model { moveSelection(model: model) }
        }
        .onChange(of: appState.lastDisposedEnvelope) { _, signal in
            // Detail view archived / trashed the current message. Advance
            // the split-view selection to the next unread envelope (so the
            // user can keep triaging without bouncing back to the list),
            // then prune the matching row so it disappears immediately.
            // Other folders ignore the signal.
            guard let signal, signal.folderPath == folder.path else { return }
            let current = model?.envelopes.first { $0.uid == signal.uid }
            // Compute the advance target before pruning - `nextUnreadEnvelope`
            // walks from `current`'s index, which disappears once it's pruned.
            let next = current.flatMap { model?.nextUnreadEnvelope(after: $0) }
            model?.pruneEnvelope(uid: signal.uid)
            if isWideLayout {
                // Wide layouts drive the reading pane off `selectedUIDs`;
                // advancing the set re-derives `selection` via the list's
                // `.onChange(of: selectedUIDs)` below.
                model?.selectedUIDs = next.map { [$0.uid] } ?? []
            } else {
                selection = next
            }
        }
        .onChange(of: appState.lastEnvelopeFlagChange) { _, signal in
            // Detail view toggled \Seen (or another flag in the future).
            // Apply it directly to the matching row so the bold styling +
            // unread dot flip without waiting for the next IDLE refresh.
            // Other folders ignore the signal.
            guard let signal, signal.folderPath == folder.path else { return }
            model?.applyFlagChange(
                uid: signal.uid,
                flag: signal.flag,
                added: signal.added
            )
        }
        // Push the selected envelope's true source folder up to the
        // root view. In folder mode this is always `folder.path`; in
        // cross-folder search mode the model's `sourceFolder(for:)`
        // returns the per-row mailbox so the detail view's operations
        // (mark read, archive, move) land in the right place.
        .onChange(of: selection) { _, newSelection in
            guard let model else { return }
            let resolved = newSelection.map(model.sourceFolder(for:))
            let projected = resolved.flatMap { $0 == folder.path ? nil : $0 }
            onSearchResultSelected(projected)
        }
        // A folder row in the sidebar received a dropped message (or
        // selection). The drop handler posts the destination + payload on
        // AppState; route it through the view model so the move shares the
        // optimistic-prune / unread-count / cache-cleanup path with the
        // bulk and menu-driven moves. Only the list the drag came from has a
        // model holding those UIDs, so other folders' lists no-op.
        .onChange(of: appState.pendingMoveRequest) { _, request in
            guard let request, let model else { return }
            Task { await model.applyMoveRequest(request) }
        }
        // A cross-client restore / jump was scheduled. For an already-mounted
        // list (a same-folder jump) the initial-load consume has long since
        // run, so re-apply here; a folder-switch jump re-mounts the list and
        // is handled by the `.task` consume instead. `consumePendingRestore`
        // makes the two paths idempotent.
        .onChange(of: appState.navCoordinator?.pendingRestore) { _, _ in
            if let model { applyPendingRestore(model: model) }
        }
    }

    /// Selects the message named by a pending cross-client restore, if it
    /// targets this folder and is present in the loaded window. Matches by
    /// Message-ID first (survives the message being moved by another client),
    /// then by UID. A miss (deleted, or not in the loaded window) leaves the
    /// list unselected — the graceful-degradation path.
    private func applyPendingRestore(model: MessageListViewModel) {
        guard !isSearchScope,
              let restore = appState.navCoordinator?.consumePendingRestore(for: folder.path)
        else { return }
        let match = restore.messageID.flatMap { messageID in
            model.envelopes.first { $0.messageId == messageID }
        } ?? restore.uid.flatMap { uid in
            model.envelopes.first { $0.uid == uid }
        }
        guard let match else { return }
        if isWideLayout {
            // Wide layouts drive the reading pane off `selectedUIDs`; the list's
            // own `.onChange(of: selectedUIDs)` re-derives `selection`.
            model.selectedUIDs = [match.uid]
        } else {
            selection = match
        }
    }
}
