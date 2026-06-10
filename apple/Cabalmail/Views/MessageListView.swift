import SwiftUI
import CabalmailKit
#if canImport(AppKit)
import AppKit
#endif

/// Envelope list for a single folder. Selection is lifted to the parent so
/// the split view can bind the detail pane to it.
struct MessageListView: View {
    let folder: Folder
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
    // `model` and `filtersPresented` are module-internal (no access
    // modifier) so the same-module extensions in `+Search` and `+macOS`
    // can read them without round-tripping through accessors.
    @State var model: MessageListViewModel?
    @State private var composeSeed: Draft?
    /// `true` while the filter sheet is presented over the message list.
    @State var filtersPresented = false
    /// Set by the row context menu's "Move to folder…" item; presents the
    /// MoveToFolderSheet anchored to this envelope. `Envelope` is
    /// `Identifiable` so `.sheet(item:)` reuses the same presentation
    /// machinery as composeSeed.
    @State var envelopeToMove: Envelope?
    /// Set by the swipe / context-menu delete while the list shows Trash;
    /// presents the "Delete Forever?" confirmation anchored to this
    /// envelope. Non-private so the `+Rows` extension can stage it.
    @State var envelopeToPurge: Envelope?
    /// `true` while the bulk-move destination picker is presented.
    @State var bulkMoveSheetPresented = false
    /// `true` while the unsubscribed-folder banner's Refresh button is
    /// in flight. The banner lives in `+UnsubscribedBanner.swift`;
    /// hoisting the flag here lets the `safeAreaInset` builder see it
    /// without a separate `@State` per inset.
    @State var unsubscribedRefreshInFlight = false
    /// macOS focus state for the inline search field. Drives the
    /// "show the search-refinement filter button only while the user
    /// is engaged with search" rule. The iOS / iPadOS / visionOS path
    /// reads `\.isSearching` from the `.searchable` scope instead — see
    /// `SearchActiveScope` in `MessageListView+Filter.swift`.
    @FocusState var inlineSearchFocused: Bool
    #if !os(macOS)
    /// Drives the native multi-select edit mode on wide touch layouts (iPad,
    /// visionOS): the Select button toggles it, and while active the system
    /// draws selection circles and taps toggle membership in `selectedUIDs`.
    /// Non-private so the `+Bulk` extension's `selectButton` can flip it.
    /// macOS has no `EditMode` (pointer shift/command-clicks cover multi-
    /// select), so this is compiled out there.
    @State var editMode: EditMode = .inactive
    #endif

    var body: some View {
        Group {
            if let model {
                content(for: model)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            // Compose stays as a toolbar item — it's a primary action
            // pinned to the top edge in every Mac mail client. The list-
            // shaping controls (filter / sort / select) moved into an
            // inline action bar above the list (see `topInset` below);
            // on wide screens the right-edge toolbar placement put them
            // visually farther from the list they affect than the
            // filter tabs that sat one row higher.
            ToolbarItem {
                Button {
                    presentCompose(seed: ReplyBuilder.newDraft())
                } label: {
                    Image(systemName: "square.and.pencil")
                        .accessibilityLabel("New Message")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            #if os(macOS)
            // Force-reload button. macOS only — iOS / iPadOS / visionOS
            // users reach the cheap merge-refresh via pull-to-refresh,
            // which is the gesture those platforms expect. Routed
            // through `requestRefresh()` so the toolbar button and the
            // Mailbox > Refresh menu item share one code path — both
            // land on `MessageListViewModel.hardReload()`, which wipes
            // in-memory state before the server fetch so the user has a
            // reliable escape from any stale-state bug the merge path
            // doesn't catch.
            ToolbarItem {
                Button {
                    appState.requestRefresh()
                } label: {
                    RefreshActivityIcon(isLoading: model?.isLoading == true)
                        .accessibilityLabel("Refresh")
                }
                .disabled(model == nil || model?.isLoading == true)
            }
            #endif
        }
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
        .confirmationDialog(
            "Delete Forever?",
            isPresented: purgeDialogBinding,
            titleVisibility: .visible,
            presenting: envelopeToPurge
        ) { envelope in
            Button("Delete Forever", role: .destructive) {
                envelopeToPurge = nil
                if let model {
                    Task { await model.purge(envelope) }
                }
            }
            Button("Cancel", role: .cancel) {
                envelopeToPurge = nil
            }
        } message: { _ in
            Text("This message will be permanently deleted. This can't be undone.")
        }
        .task {
            if model == nil, let client = appState.client {
                model = MessageListViewModel(
                    folder: folder,
                    client: client,
                    preferences: preferences,
                    appState: appState
                )
                await model?.loadInitial()
                await model?.startWatching()
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
    }

    /// Boolean projection of `envelopeToPurge` for the confirmation
    /// dialog. Mirrors `FoldersAdminView`'s delete-dialog binding.
    private var purgeDialogBinding: Binding<Bool> {
        Binding(
            get: { envelopeToPurge != nil },
            set: { isPresented in
                if !isPresented { envelopeToPurge = nil }
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
        // iPadOS/iOS/visionOS — `.searchable` lands the search bar above
        // the content column's list, exactly where we want it. macOS
        // routes the same modifier to the window toolbar at the trailing
        // edge, which visually parks the search box over the detail
        // (message body) column. Rendering an inline search field via
        // `.safeAreaInset` below keeps macOS looking like iPad.
        #if !os(macOS)
        .searchable(text: $model.searchQuery, prompt: "Search mailbox")
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
        #endif
        // Drop search mode when the field is cleared. `.searchable`'s
        // built-in × / Cancel buttons and the macOS inline field's clear
        // button all just zero out the binding without firing
        // `.onSubmit(of: .search)`, so without this the user would be
        // stuck with stale search results and no path back to the
        // folder view short of running a different query.
        .onChange(of: model.searchQuery) { _, newValue in
            guard model.isSearchActive,
                  newValue.trimmingCharacters(in: .whitespaces).isEmpty
            else { return }
            Task { await model.clearSearch() }
        }
        .refreshable {
            await model.refresh()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topInset(model: model) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if !folder.isSubscribed {
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
