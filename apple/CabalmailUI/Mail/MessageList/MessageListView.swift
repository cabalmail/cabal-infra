import SwiftUI
import CabalmailKit

/// Envelope list for a single folder. Selection is lifted to the parent so
/// the split view can bind the detail pane to it.
struct MessageListView: View {
    /// What this list shows — a folder or the global search surface. Drives the
    /// title, the top-inset chrome (filter pills vs. search-result banner), and
    /// whether the folder lifecycle (initial load / the folder's poller) runs.
    let scope: MessageListScope
    /// Parent-owned view model for `.search` scope (so the search input —
    /// `.searchable` on iPhone, the sidebar field on iPad/macOS — can bind the
    /// same model). Nil in folder scope: the view self-creates the folder model
    /// in `.task` and owns its full lifecycle.
    var injectedSearchModel: MessageListViewModel?
    /// The folder this list shows; nil on the global search surface, which
    /// shows none. The folder-only chrome unwraps it.
    var folder: Folder? { scope.folder }
    /// True for the global search surface.
    var isSearchScope: Bool { scope.isSearch }
    /// The row the reader shows. Every row carries its own folder
    /// (`Envelope.folder`), so the host opens the reader against the
    /// message's true mailbox (`MessageFolderPolicy`) — a cross-folder search
    /// result included — rather than the sidebar's current selection.
    @Binding var selection: Envelope?
    /// Reports how many messages are currently selected so the parent can show
    /// a "N messages selected" placeholder in the reading pane during a multi-
    /// selection. Fires only on wide/keyboard layouts, where the native multi-
    /// select list drives `selectedRefs`; compact iPhone keeps the single-
    /// selection + touch edit-mode flow and never calls this.
    let onSelectionCountChanged: (Int) -> Void
    /// Fires when the user picks another folder from the folder-switch menu
    /// behind the list's title (see `+FolderSwitch`). The parent owns the
    /// selection, so it applies the pick exactly as a sidebar tap would.
    /// Defaults to a no-op for hosts with no folder selection (search).
    var onSwitchFolder: (Folder) -> Void = { _ in }
    /// Reports the measured width of the macOS folder-switch menu in the
    /// column's toolbar section (see `+FolderSwitch`), so the host can size
    /// the global search field that shares the section around it
    /// (`ToolbarSearchFieldWidth`). Never fires on the other platforms,
    /// where the menu is the system title menu and takes no toolbar width.
    /// Defaults to a no-op for hosts that don't seat a field there.
    var onFolderMenuWidthChanged: (CGFloat) -> Void = { _ in }

    // `appState` is not private so the +Bulk sibling can reach it for
    // the move-destination sheet's `client` lookup; matches the pattern
    // used for `model` and `filtersPresented` further down.
    @Environment(AppState.self) var appState
    @Environment(Preferences.self) private var preferences
    /// The window's navigation, which holds a folder list's selection so a
    /// layout swap can hand it to the list the new layout builds
    /// (`SceneNavigator.mailSelection(for:)`). Optional so a list hosted
    /// outside a main window still builds, with a selection of its own.
    @Environment(SceneNavigator.self) private var navigator: SceneNavigator?
    #if !os(macOS)
    // Wide vs. compact gates whether message rows are draggable. On a
    // compact iPhone the sidebar and the message list never share the
    // screen, so there's nowhere to drop a message, and a long-press drag
    // would only fight each row's context menu. Non-private so the `+Rows`
    // extension that builds the rows can read it. macOS has no size class
    // and is always treated as wide (see `isWideLayout`).
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    // Whether the wide single-rail layout is active (regular-width iPad,
    // visionOS). Decides where the folder switch is drawn: a column-scoped
    // bar can't host it (`FolderSwitchPlacement`, #1626). A plain flag rather
    // than the size class above for the reason its own doc gives — this is a
    // narrow split column and reports compact even on a regular-width iPad.
    @Environment(\.showsSettingsGear) var showsSettingsGear
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
    /// Gates for the launch restore — see `applyPendingRestoreWhenReady`.
    @State private var hasAppeared = false
    @State private var initialLoadComplete = false
    /// The folder list the folder-switch menu offers, loaded once per mount
    /// by `loadFolderSwitchChoices()` (`+FolderSwitch`). Empty until then.
    @State var switchFolders: [Folder] = []
    /// The "Mark all messages in … as read?" confirmation (`+MarkAllRead`),
    /// staged by the toolbar's More menu and the Mailbox menu's ⌥⌘T.
    @State var markAllReadConfirmPresented = false
    /// This window's identity, for aiming its own compose and refresh
    /// requests at itself (`MainWindowCommandScope`).
    @Environment(\.commandWindowID) var commandWindowID
    /// This list's identity, carried on the drags it starts so that only
    /// it performs the move a sidebar drop posts (`MessageMoveRequest`).
    @State var dragSourceID = UUID()
    /// How far this view has applied its model's selection reactions
    /// (`ListSelectionReactions.tick`). Kept per view, since a model can be
    /// shown by two windows at once (the shared search model).
    @State var appliedSelectionReactions = 0
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
    /// `SwipeActionRow` List (its pre-27 path) began scrolling its own clipped
    /// content, capturing the drag meant to scroll the whole list.
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
    /// MoveToFolderSheet anchored to this envelope via `.sheet(item:)`
    /// (`Envelope` is `Identifiable`).
    @State var envelopeToMove: Envelope?
    /// Set by the delete affordances while the list shows Trash (row
    /// swipe / menu for a single message; selection menu, action bar,
    /// and Cmd+Delete for a multi-selection); presents the "Delete
    /// Forever?" confirmation for the captured messages. Non-private so
    /// the `+Rows` / `+Bulk` / `+Actions` extensions can stage it.
    @State var purgeCandidate: PurgeCandidate?
    /// Set by `requestDispose` when a dispose crosses the large-selection
    /// threshold; presents the "Archive/Delete N Messages?" confirmation
    /// (see `MessageListView+Actions.swift`). Non-private for the same
    /// reason as `purgeCandidate`.
    @State var disposeCandidate: DisposeCandidate?
    /// `true` while the bulk-move destination picker is presented.
    @State var bulkMoveSheetPresented = false
    /// Set by the wide-layout selection context menu's "Move to folder…"
    /// item and the Cmd+M shortcut; presents the MoveToFolderSheet for
    /// the captured messages (see `MessageListView+Actions.swift`).
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

    // `body` was a single ~200-line modifier chain; once the sheets, the
    // purge confirmation, and the observers were all attached,
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
                if !isPresented { withdrawPurgeCandidate() }
            }
        )
    }

    /// Closes the "Delete Forever?" dialog without deleting anything. A full
    /// swipe's Delete Forever holds its row slid open while the dialog asks,
    /// and nothing but a new row lets go of that, so the candidate's rows come
    /// back replaced (`replaceRows(showing:)`). Confirming takes the same
    /// care inside `purgeMessages`; by the time a confirmed dialog dismisses,
    /// the candidate is already cleared and this does nothing.
    private func withdrawPurgeCandidate() {
        if let candidate = purgeCandidate {
            model?.replaceRows(showing: candidate.refs)
        }
        purgeCandidate = nil
    }

    /// Boolean projection of `disposeCandidate`, same shape as above.
    private var disposeDialogBinding: Binding<Bool> {
        Binding(
            get: { disposeCandidate != nil },
            set: { isPresented in
                if !isPresented { disposeCandidate = nil }
            }
        )
    }

    /// Title for the large-selection dispose confirmation. Computed off
    /// the staged candidate because `confirmationDialog`'s title is a
    /// plain value, not a `presenting:` closure.
    private var disposeDialogTitle: String {
        guard let candidate = disposeCandidate else { return "" }
        let verb = candidate.action == .trash ? "Delete" : "Archive"
        return "\(verb) \(candidate.refs.count) Messages?"
    }

    @ViewBuilder
    private func moveSheet(for envelope: Envelope) -> some View {
        if let client = appState.client {
            // A cross-folder search row's mailbox is its own, not the
            // list's `folder` (the search scope). Excluding the row's
            // actual folder from the picker is what the user expects.
            MoveToFolderSheet(
                currentFolder: MessageFolderPolicy.folder(for: envelope, in: folder) ?? folder,
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

    /// Routes to the app-wide compose receiver (`ComposeRequestRouter`
    /// on `SignedInRootView`), which opens a compose window on the
    /// platforms that support one and hosts the compose sheet on
    /// iPhone. Presentation is deliberately NOT view-local: a sheet
    /// anchored here can't present when this view isn't visible, and
    /// two competing sheet hosts would block each other.
    private func presentCompose(seed: Draft) {
        appState.requestCompose(seed: seed, in: commandWindowID)
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
        // An empty results area is ambiguous on a submit-driven search, so it
        // says which of the two it is (#1027).
        .overlay {
            searchResultsPlaceholder(model: model, visibleRowCount: visible.count)
        }
        // A search/filter list that empties out from under the user (every
        // loaded Unread row marked read, say) has no rows left to fire the
        // near-end prefetch, so kick the next page from here instead. The
        // model's guards make this a no-op outside an active search or once
        // the cursor runs dry.
        .onChange(of: visible.isEmpty) { _, isEmpty in
            guard isEmpty, model.isSearchActive else { return }
            model.search.requestMore()
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
                if let folder,
                   UnsubscribedBannerPolicy.shouldShow(
                       folder: folder, subscribedPaths: appState.mailStore.counts.subscribedFolderPaths
                   ) {
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
        markAllReadChrome(folderSwitchTitle(
            Group {
                if let model {
                    content(for: model)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(folder?.name ?? "Search")
        ))
        // The folder-switch menu's rows (`+FolderSwitch`); a no-op on the
        // search surface.
        .task { await loadFolderSwitchChoices() }
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
            // MessageDetailView's eleven buttons) gets crowded — the
            // reader's buttons are deliberately NOT grouped, so that they
            // evict one at a time in priority order (#1047), but these two
            // must never be what the window gives up.
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
                    appState.requestRefresh(in: commandWindowID)
                } label: {
                    RefreshActivityIcon(isLoading: model?.isLoading == true)
                        .accessibilityLabel("Refresh")
                }
                .disabled(model == nil || model?.isLoading == true)
            }
            // Never the pair the » popup takes (see above); on 26.1+ the
            // system honours that as a priority rather than by our ordering.
            .keepsInBar()
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
            // Compose is the list's one frequent action: on an iPhone Duo's
            // vertical bar it must survive the overflow that the outer
            // display's short strip forces (#1647).
            .keepsInBar()
            #endif
        }
    }

    /// Sheets and confirmation dialogs presented over the list.
    private var presentationLayer: some View {
        chromeLayer
        .sheet(isPresented: $filtersPresented) {
            filtersSheet
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
                    Task { await model.purgeMessages(refs: candidate.refs) }
                }
            }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {
                withdrawPurgeCandidate()
            }
        } message: { candidate in
            Text(
                candidate.refs.count == 1
                ? "This message will be permanently deleted. This can't be undone."
                : "These \(candidate.refs.count) messages will be permanently deleted. This can't be undone."
            )
        }
        // Large-selection dispose guard (threshold in `+Actions.swift`):
        // recoverable, unlike the purge above, but big enough that a
        // mis-aimed select-all shouldn't file everything silently.
        .confirmationDialog(
            disposeDialogTitle,
            isPresented: disposeDialogBinding,
            titleVisibility: .visible,
            presenting: disposeCandidate
        ) { candidate in
            Button(
                candidate.action == .trash ? "Delete" : "Archive",
                role: candidate.action == .trash ? .destructive : nil
            ) {
                disposeCandidate = nil
                if let model {
                    commitDispose(candidate, model: model)
                }
            }
            Button("Cancel", role: ConfirmationDialogPolicy.backOutRole) {
                disposeCandidate = nil
            }
        } message: { candidate in
            Text(
                candidate.action == .trash
                ? "\(candidate.refs.count) messages will be moved to Trash."
                : "\(candidate.refs.count) messages will be archived."
            )
        }
    }

    /// Lifecycle: initial load, then the list on its folder's poller
    /// (`FolderPollers`: the change watcher and the 60-second tick), and off
    /// it again when the list leaves the screen.
    private var lifecycleLayer: some View {
        presentationLayer
        .task {
            if model == nil, let client = appState.client {
                if isSearchScope {
                    // Parent owns the search model (its query is bound by the
                    // external search input). No folder load / watcher here — it
                    // populates only when a search runs. Every window shares it,
                    // so this view applies its selection reactions from here
                    // on, not another window's from before it opened.
                    model = injectedSearchModel
                    appliedSelectionReactions = injectedSearchModel?.selectionReactions.tick ?? 0
                } else {
                    model = MessageListViewModel(
                        scope: scope,
                        client: client,
                        preferences: preferences,
                        mailStore: appState.mailStore,
                        selection: folder.flatMap { navigator?.mailSelection(for: $0.path) }
                    )
                    await model?.loadInitial()
                    await model?.startWatching()
                    // Cross-client restore: if this folder is the saved
                    // cursor's target, select the remembered message now that
                    // its envelope is loaded — but only once the list is on
                    // screen (`applyPendingRestoreWhenReady`), so the reader
                    // is pushed in a later update than the list (#1664).
                    initialLoadComplete = true
                    applyPendingRestoreWhenReady()
                }
            } else if !isSearchScope {
                // Back on screen with the model it kept (a reader pushed over
                // the list and popped): `.onDisappear` took it off its
                // folder's poller, so put it back (#1816; a no-op while it is
                // on), and refresh for whatever arrived while the list was
                // away, which no poll of its folder handed it.
                await model?.startWatching()
                await model?.refresh()
            }
        }
        .onAppear {
            hasAppeared = true
            applyPendingRestoreWhenReady()
        }
        .onDisappear {
            // Take the list off its folder's poller when it drops off-screen;
            // the last list off a folder stops its watcher and tick. The view
            // is rebuilt (via `.id(folder.path)` in MailRootView) when the
            // user picks another folder, so `startWatching` in the new
            // instance's `.task` puts the new list on the new folder's
            // poller; the same view coming back puts it back too.
            let model = model
            Task { await model?.stopWatching() }
        }
    }

    /// Observers: `AppState`'s menu / shortcut ticks, the selection
    /// reactions the model queues from mail events, and drag-and-drop move
    /// requests.
    private var observersLayer: some View {
        lifecycleLayer
        // macOS Commands menu (Mailbox → Refresh) and keyboard shortcuts
        // route through `AppState` tick counters. Using the currently-
        // displayed list as the refresh target matches every desktop mail
        // client's convention. (`composeRequestTick` is consumed by
        // `ComposeRequestRouter` on the signed-in root, not here — this
        // view isn't in the visible hierarchy in every state a compose
        // request can arrive from.)
        .onWindowCommand(appState.refreshRequestTick) {
            // Manual refresh paths (Mailbox > Refresh menu item, the
            // arrow.clockwise toolbar button) get hard-reload semantics
            // — wipe in-memory state before refresh — so the user has a
            // reliable escape from any stale-state bug the merge path
            // doesn't catch. The folder's poller keeps handing the list an
            // ordinary `refresh(prefetched:)`; it fires too often to be
            // discarding cached envelopes on every tick.
            Task { await model?.hardReload() }
        }
        // Message-menu chords (Cmd+T / Cmd+Shift+8 / Cmd+M) acting on the
        // current selection. Handlers live in `MessageListView+Actions.swift`;
        // each no-ops when nothing is selected.
        .onWindowCommand(appState.toggleSeenRequestTick) {
            if let model { toggleSeenOnSelection(model: model) }
        }
        .onWindowCommand(appState.toggleFlaggedRequestTick) {
            if let model { toggleFlaggedOnSelection(model: model) }
        }
        .onWindowCommand(appState.moveSelectionRequestTick) {
            if let model { moveSelection(model: model) }
        }
        // What the reader's and the composer's changes ask of this list's
        // selection. The model hears the mail events itself, for its whole
        // life, and drops or restores the rows; it queues what the selection
        // should do (worked out before the rows left) for this view, which
        // owns the selection on compact layouts. Every queued reaction is
        // applied, in order (`applySelectionReactions`, in `+Actions`).
        .onChange(of: model?.selectionReactions.tick) { _, _ in
            if let model { applySelectionReactions(model: model) }
        }
        // A folder row in the sidebar received a dropped message (or
        // selection). The drop handler posts the destination + payload on
        // AppState; route it through the view model so the move shares the
        // optimistic-prune / unread-count / cache-cleanup path with the
        // bulk and menu-driven moves. Every mounted list in every window sees
        // the request, so only the list the drag lifted from performs it.
        .onChange(of: appState.pendingMoveRequest) { _, request in
            guard let request, let model, request.isPerformed(by: dragSourceID) else { return }
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

    /// The launch restore's two gates: the list has appeared, and its initial
    /// load has run. Selecting the remembered message before both hold either
    /// finds no envelopes to match (too early) or pushes the reader in the
    /// same update as the list — and on a compact stack the reader UIKit then
    /// shows is not the one SwiftUI runs `onAppear` for, so it never loads
    /// (#1664; see `FeedRootView` for the measured case). Whichever gate
    /// closes last applies the restore; `consumePendingRestore` keeps the
    /// two call sites idempotent.
    private func applyPendingRestoreWhenReady() {
        guard hasAppeared, initialLoadComplete, let model else { return }
        applyPendingRestore(model: model)
    }

    /// Selects the message named by a pending cross-client restore, if it
    /// targets this folder and is present in the loaded window. Matches by
    /// Message-ID first (survives the message being moved by another client),
    /// then by the restore's ref. A miss (deleted, or not in the loaded
    /// window) leaves the list unselected — the graceful-degradation path.
    private func applyPendingRestore(model: MessageListViewModel) {
        guard let folder,
              let restore = appState.navCoordinator?.consumePendingRestore(for: folder.path)
        else { return }
        let match = restore.messageID.flatMap { messageID in
            model.envelopes.first { $0.messageId == messageID }
        } ?? restore.ref.flatMap(model.envelope(for:))
        guard let match else { return }
        if isWideLayout {
            // Wide layouts drive the reading pane off `selectedRefs`; the list's
            // own `.onChange(of: selectedRefs)` re-derives `selection`.
            model.selectedRefs = [model.rowRef(for: match)]
        } else {
            selection = match
        }
    }
}
