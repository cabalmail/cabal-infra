import Foundation
import Observation
import CabalmailKit

/// Backs `MessageListView`: one folder's list, or the global search surface.
/// It coordinates the parts that show the rows -- the folder window
/// (`window`, a `FolderWindowLoader`: rows, positions, paging, refresh and
/// the snapshot) and, while one runs, a search in its place -- and owns what
/// spans them: the filter pills, the selection, the writes made from the
/// list and the events it hears from other writers, and the routing of a
/// refresh to whichever part is showing.
@Observable
@MainActor
final class MessageListViewModel {
    /// What this list is showing — a folder or the global search surface.
    /// `.search` runs no folder lifecycle; see `MessageListScope`.
    let scope: MessageListScope
    /// Resolved anchor folder (a sentinel in `.search` scope). Folder-keyed
    /// call sites read this unchanged; the search paths are gated off before
    /// any of them issue an IMAP request against a `.search` sentinel.
    let folder: Folder
    let client: CabalmailClient
    let preferences: Preferences
    /// The session's shared mail state: the folder counts this list keeps
    /// the sidebar's in step with, and the shields its merges honour.
    let mailStore: MailSessionStore
    /// The folder window: its rows, their positions and every load that
    /// fills them. Views and tests reach window state through it.
    let window: FolderWindowLoader

    var errorMessage: String?

    /// Active filter tab. Narrows the loaded envelopes client-side and, for
    /// Unread / Flagged, drives the folder-scoped server search that loads
    /// them (`selectFilter`). Sticky per folder: a rebuilt view-model
    /// (folder switch, relaunch) opens on the pill the user last chose for
    /// this folder (`Preferences.mailFolderFilters`), All until then.
    var filterTab: MessageFilter = .all

    /// True when the user has tapped Select; rows render checkboxes and
    /// the per-row tap selects rather than opening the detail pane.
    var bulkMode: Bool = false

    /// The rows the user has selected: on wide layouts every selection
    /// (one row opens the reader), on touch layouts the Select mode's
    /// checkboxes. Keyed by `MessageRef`, so of two search rows that share a
    /// UID exactly the one picked is selected, and every action on the
    /// selection reaches exactly the messages in it.
    var selectedRefs: Set<MessageRef> = []

    /// Anchor row for range selection: the fixed pivot a shift-click or
    /// shift-arrow extends from -- the last row plainly selected or
    /// command-clicked. Settable only through `setSelectionAnchor(_:)`, so
    /// it cannot drift out of step with `selectionRangeBase`.
    private(set) var selectionAnchor: MessageRef?

    /// The selection a range operation extends *from*: whatever was selected
    /// at the moment `selectionAnchor` was pinned.
    ///
    /// A shift-click unions its span onto this rather than replacing the
    /// selection, which is how rows picked with command outside the span
    /// survive (#1768). It is never written on its own -- a base left over
    /// from an earlier anchor would resurrect rows the user has since
    /// dropped -- which is what `setSelectionAnchor(_:)` enforces.
    private(set) var selectionRangeBase: Set<MessageRef> = []

    /// Pin the pivot for range selection, recording the selection it starts
    /// from. The anchor and its base always move together.
    func setSelectionAnchor(_ ref: MessageRef?) {
        selectionAnchor = ref
        selectionRangeBase = selectedRefs
    }

    /// The moving end of a keyboard range selection (the row a plain arrow
    /// last landed on, or a shift-arrow last extended to). Distinct from the
    /// anchor so shift-arrow grows/shrinks the range from the right end rather
    /// than collapsing it. Plain selection sets cursor == anchor.
    var selectionCursor: MessageRef?

    /// Free-text term submitted from the search field. Filters live in
    /// `searchFilters`; the two are sent together when `runSearch()` runs.
    var searchQuery: String = ""

    /// Structured filter form state — mirrors the React filter panel.
    var searchFilters = MessageSearchFilters()

    /// The folder the global search surface's "This folder only" narrows to:
    /// the wide layout's sidebar selection, fed in through
    /// `setSearchAnchor(_:)`. Unused in folder scope, which narrows to
    /// `folder`; see `searchFolder`.
    var searchAnchor: Folder?

    /// The trimmed term the most recent submitted search ran with. Distinct
    /// from `searchQuery`, which tracks the field as the user types: search is
    /// submit-driven, so the two diverge for every keystroke between typing
    /// and Return, and that gap is what tells a pending query from an
    /// exhausted one.
    /// Written by `runSearch()` / `clearSearch()` only.
    var submittedQuery: String = ""

    /// `true` while search results are showing in `envelopes`.
    var isSearchActive: Bool = false

    /// Search-banner metadata. All zero when no search is active.
    var searchTotalEstimate: Int = 0
    var searchTruncated: Bool = false
    var searchFoldersSearched: [String] = []

    /// Opaque next-page cursor for the active search; nil = every match
    /// loaded (or no search active). Cleared before every fresh search so
    /// an in-flight load-more can detect it raced a reset and drop its
    /// page. Written by the `+Search.swift` extension only.
    var searchNextCursor: String?

    /// A search load-more page is in flight — guards re-entry and drives
    /// the list's tail spinner.
    var isLoadingMoreSearch = false

    /// Model-owned task for the search load-more fetch, so it outlives the
    /// triggering row's `.task` cancellation (the `loadMoreTask` pattern).
    var loadMoreSearchTask: Task<Void, Never>?

    /// Foreground-only change watcher (`MailboxWatcher`, which polls folder
    /// status). Nil when the view is offscreen; started on
    /// `task`, stopped on `onDisappear`. Separated from the refresh path so
    /// UIDVALIDITY changes, pagination, and flag toggles never fight the
    /// watcher for the main actor.
    private var watcher: MailboxWatcher?
    private var watcherTask: Task<Void, Never>?
    /// Coalescing timestamp — if `.changed` fires in bursts (e.g. server
    /// delivers three messages in quick succession) we collapse them into
    /// one refresh by gating on elapsed time.
    private var lastRefreshFromWatcher: Date = .distantPast

    // A refresh dispatched just before a write lands returns the row's
    // pre-write server state; applying it verbatim would resurrect a row
    // just moved or revert a flag just toggled. Every write, this list's or
    // anyone's, is bracketed in the mail store's one record
    // (`MessageShields`), which the window's merges, the refresh's STATUS
    // bounds and the paging gate ask.

    /// Rows `pruneEnvelope(_:)` took out for a dispose / move / purge made by
    /// the reader or another list that is still in flight, with the index
    /// each held, so a failed server write can put the row back
    /// (`restorePrunedEnvelope`). The rows are this list's own (rows stay in
    /// each list); whether their removal is still in flight is the record's.
    /// Only in-flight removals are kept, so it holds a handful at most. (The
    /// name predates the other lists' removals reaching this list.)
    @ObservationIgnored var readerPrunedEnvelopes: [MessageRef: (envelope: Envelope, index: Int)] = [:]
    /// Removals whose failure reached this list while it still had the row:
    /// the next prune of the message is skipped if no removal is in flight
    /// behind it. See `pruneEnvelope(_:)`.
    @ObservationIgnored var readerFailedRefs: Set<MessageRef> = []

    /// Rows mid-disposal animation. A disposed row stays in `envelopes`
    /// while it fades and then collapses (see `beginRowDisposal` in
    /// `+Optimistic`), so the list closes the gap visibly instead of
    /// instantaneously. Empty except during those ~300ms.
    var rowDisposalPhases: [MessageRef: RowDisposalPhase] = [:]

    /// Generation of each replaced slot of the virtualized list, keyed by
    /// absolute index; an absent index is generation 0. Part of the row's
    /// identity (`MessageListSlot`), so a bump gives that slot a new row --
    /// see `replaceRows(showing:)` in `+RowReplacement`.
    var slotGenerations: [Int: Int] = [:]
    /// The same for the filtered / search list, whose rows are keyed by
    /// message (`MessageRowIdentity`) rather than by slot.
    var rowGenerations: [MessageRef: Int] = [:]

    /// What the mail events this list heard ask of its selection, for its
    /// view to apply (`receive(_:)`, `MailEventSelectionPolicy`).
    let selectionReactions = ListSelectionReactions()

    init(scope: MessageListScope, client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore) {
        self.scope = scope
        self.folder = scope.folder
        self.client = client
        self.preferences = preferences
        self.mailStore = mailStore
        self.window = FolderWindowLoader(scope: scope, client: client, mailStore: mailStore)
        window.host = self
        // For the model's whole life, not the view's: a list under a pushed
        // reader has had `.onDisappear` and still has to hear its archive.
        mailStore.events.subscribe(self)
    }

    /// The rows on screen: the folder window's, or a search's in their place
    /// (both live in the window's array until the search moves out). The
    /// `_modify` accessor hands the window's storage through, so an in-place
    /// edit (a flag flip, a removal) doesn't copy the whole array.
    var envelopes: [Envelope] {
        get { window.envelopes }
        set { window.envelopes = newValue }
        _modify { yield &window.envelopes }
    }

    /// A refresh, a reset or a search is in flight (`FolderWindowLoader.isLoading`).
    var isLoading: Bool { window.isLoading }

    /// The removals in flight that touch this list: its folder's, from any
    /// writer, or on the search surface any. It includes, on the dispose
    /// path, the few hundred milliseconds where the row is still present but
    /// animating out (`rowDisposalPhases`).
    var pendingRemovedRefs: Set<MessageRef> { window.pendingRemovedRefs }

    /// Start the watcher-driven auto-refresh loop. Called from the view's
    /// `.task` after `loadInitial()` settles. The watcher runs on its own
    /// actor and emits `.changed` whenever a folder-status poll shows an
    /// arrival (`UIDNEXT` advanced) or a removal (the count dropped); we
    /// collapse bursts to a single refresh by gating on elapsed time, since
    /// one poll can report both.
    func startWatching() async {
        // The global search surface has no anchor folder to watch.
        guard !isSearchScope, watcher == nil else { return }
        let client = self.client
        let watcher = MailboxWatcher(
            folder: folder.path,
            streamFactory: { folder in
                try await client.imapClient.idle(folder: folder)
            }
        )
        self.watcher = watcher
        let stream = await watcher.start()
        watcherTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled, let self else { break }
                if case .changed = event {
                    await self.handleWatcherChanged()
                }
            }
        }
    }

    /// Tear down the watcher. View hooks this into `.onDisappear` so the
    /// status polling stops when the list isn't on screen — no API calls
    /// for a mailbox the user isn't looking at. The window's own tasks stop
    /// with it, before any suspension.
    func stopWatching() async {
        watcherTask?.cancel()
        watcherTask = nil
        window.cancelTasks()
        // Let go of the watcher before waiting for it to stop, so a list back
        // on screen in the meantime starts a fresh one (`startWatching`).
        let stopping = watcher
        watcher = nil
        await stopping?.stop()
    }

    private func handleWatcherChanged() async {
        // Coalesce bursts: one status poll can report both an arrival and a
        // removal, and one refresh covers both.
        let now = Date()
        guard now.timeIntervalSince(lastRefreshFromWatcher) > 1 else { return }
        lastRefreshFromWatcher = now
        await refresh()
    }

    /// Brings the list up to date with the server: while a search is
    /// showing, that search again; otherwise the folder window's
    /// single-flight refresh (`WindowRefresher`). `prefetched` is a STATUS
    /// already asked for; `startingOver` marks a reset's refresh, which runs
    /// at once.
    func refresh(prefetched: PrefetchedStatus? = nil, startingOver: Bool = false) async {
        // Re-route while a search is showing — pull-to-refresh and the
        // watcher / 60-second background refreshes shouldn't silently wipe
        // active search results back to the folder view. Re-running the
        // search keeps the result set fresh against any concurrent
        // mailbox churn.
        if isSearchActive {
            await refreshSearch(prefetched: prefetched)
            return
        }
        await window.refresh(prefetched: prefetched, startingOver: startingOver)
    }

    /// Messages this list removed are confirmed gone on the server (a
    /// dispose, move or purge landed; the mutation service has already
    /// forgotten them in the offline caches), so a bottom window staged at
    /// the old positions is misaligned -- drop it. The in-flight removal
    /// already blocks adoption via `ensureLoaded`'s `pendingRemovedRefs`
    /// gate; this covers the window after it clears.
    func removalsConfirmed() {
        invalidateBottomPrefetch()
    }
}

// MARK: - Internals

extension MessageListViewModel {
    /// The currently-configured dispose action, exposed so the view can
    /// render the right swipe-action label and icon without reaching into
    /// the preferences environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

    /// The swipe bindings, exposed for the same reason: the row picks the
    /// spec each edge reveals from these.
    var swipeLeading: MailSwipeAction { preferences.swipeLeading }
    var swipeTrailing: MailSwipeAction { preferences.swipeTrailing }

    /// The user's custom-flag palette, exposed for the row chips and the
    /// Flags picker menu (same narrow-accessor rationale as
    /// `disposeAction`).
    var flagPalette: [FlagPaletteEntry] { preferences.flagPalette }

    /// True when this is the global search surface (no anchor folder).
    var isSearchScope: Bool { scope.isSearch }

    /// Whether the sort menu means anything for the rows shown. Search
    /// results (a pill's included) come from the server newest first, and
    /// `SearchQuery` can't ask for another order; sorting the loaded rows
    /// here would reshuffle them under the user as each later page landed.
    /// So the menu is off during a search, rather than offering an order the
    /// rows don't take (#1822).
    var sortApplies: Bool { !isSearchScope && !isSearchActive }

    /// Convenience for the folder path — the overwhelming majority of call
    /// sites. Equivalent to `init(scope: .folder(folder), ...)`.
    convenience init(folder: Folder, client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore) {
        self.init(scope: .folder(folder), client: client, preferences: preferences, mailStore: mailStore)
    }

    /// The order the rows on screen sort in, for the writes that put a row
    /// back (`FolderWindowLoader.envelopeOrder`).
    var envelopeOrder: (Envelope, Envelope) -> Bool { window.envelopeOrder }

    /// Drops the window's staged bottom page: the rows moved under it.
    func invalidateBottomPrefetch() {
        window.invalidateBottomPrefetch()
    }

    /// Drop a message's row from the in-memory envelope list after it was
    /// disposed elsewhere (a `.removed` event: the reader's or another list's
    /// archive, move or purge, or a send from Drafts). The mutation service
    /// forgets the message in the offline caches once the server confirms;
    /// this only touches the list's in-memory copy so the row disappears
    /// immediately without a server round trip.
    ///
    /// A failure that reached this list while it still had the row (it was
    /// built while the removal was out) is remembered in `readerFailedRefs`,
    /// and swallows the next prune of that message if no removal is in
    /// flight behind it -- including a compose session's send from Drafts,
    /// which isn't recorded. It is spent on that next prune either way, so a
    /// removal made through the mutation service goes ahead.
    ///
    /// `originalIndex` is where the row was before the removal that names it
    /// pruned any of its other rows (`applyRemoval`), kept for a revert.
    func pruneEnvelope(_ ref: MessageRef, from originalIndex: Int? = nil) {
        if readerFailedRefs.remove(ref) != nil, !mailStore.shields.isRemoving(ref) { return }
        let removedIndex = index(of: ref)
        let removed = removedIndex.map { envelopes[$0] }
        if let removed, let removedIndex {
            stashForReaderRevert(removed, at: originalIndex ?? removedIndex)
        }
        let loadedBefore = envelopes.count
        if let removedIndex { envelopes.remove(at: removedIndex) }
        // Only adjust when a row really left the window: an event for a
        // message we never had loaded says nothing reliable about the folder
        // total.
        adjustTotalMessages(by: envelopes.count - loadedBefore)
        // The folder lost a row (a removal made elsewhere), so a staged
        // bottom window may no longer line up -- drop it.
        invalidateBottomPrefetch()
    }

    /// Apply a flag toggle that originated outside the list (a
    /// `.flagsChanged` event: the reader's toggles, another list's, a
    /// reply's `\Answered`).
    /// Updates the in-memory envelope so the row's bold styling and unread
    /// dot match the new state without waiting for a refresh. No-op when the
    /// message isn't currently in the window; matched by the row's ref, so
    /// on the search surface it reaches whichever row names the message
    /// (#1859).
    func applyFlagChange(_ ref: MessageRef, flag: Flag, added: Bool) {
        applyOptimisticFlag(ref, flag: flag, add: added)
    }

    /// The identity of `envelope`'s row (`FolderWindowLoader.rowRef(for:)`).
    func rowRef(for envelope: Envelope) -> MessageRef {
        window.rowRef(for: envelope)
    }

    /// Position of `ref`'s row in `envelopes`, while it is loaded.
    func index(of ref: MessageRef) -> Int? {
        envelopes.firstIndex { rowRef(for: $0) == ref }
    }

    /// The loaded row for `ref`.
    func envelope(for ref: MessageRef) -> Envelope? {
        index(of: ref).map { envelopes[$0] }
    }

    /// `fetched` placed in this folder (`FolderWindowLoader.placedInFolder(_:)`).
    func placedInFolder(_ fetched: [Envelope]) -> [Envelope] {
        window.placedInFolder(fetched)
    }
}

// MARK: - The window's host

extension MessageListViewModel: FolderWindowHost {
    /// Select mode is on with rows picked: a re-read waits rather than
    /// reshuffle the rows under the selection being built.
    var isBuildingBulkSelection: Bool { bulkMode && !selectedRefs.isEmpty }
}

// MARK: - Mail events

// The list's half of the mail store's events (`MailEvents`): what the reader,
// the composer and other lists changed, matched against this list's own rows
// by ref (its own writes aren't sent back to it). A
// folder list's rows all carry its folder; the search surface's come from
// many, and an event reaches whichever of them it names (#1877). Whatever
// the selection should do about one is queued for the view, which owns the
// selection on compact layouts (`selectionReactions`).
extension MessageListViewModel: MailEventSubscriber {
    func receive(_ event: MailEvent) {
        switch event.change {
        case .removed(let refs):
            applyRemoval(of: refs, from: event.origin, advancing: event.advances)
        case .restored(let ref, let markUnread):
            // The selection stays where the removal's advance left it, as
            // with a failed swipe.
            restorePrunedEnvelope(ref, markUnread: markUnread)
        case .flagsChanged(let refs, let flag, let added):
            for ref in refs {
                applyFlagChange(ref, flag: flag, added: added)
            }
        case .draftReplaced(let folderPath, let replacement):
            applyDraftReplacement(replacement, in: folderPath, from: event.origin)
        case .readAdvance(let ref, let advance):
            // The row stays (it is only read now), so nothing is pruned.
            guard let current = envelope(for: ref) else { return }
            let next = markReadAdvanceTarget(after: current, following: advance)
            selectionReactions.append(ListSelectionReaction(
                kind: .readAdvance, rows: [ref], target: next.map(rowRef(for:)), origin: event.origin,
                advances: event.advances
            ))
        }
    }

    /// Drops the rows `refs` names. A folder list takes every ref in its
    /// folder, loaded or not, since one it never loaded still moved the rows
    /// a staged bottom window holds (`pruneEnvelope`); the search surface
    /// takes the rows it lists.
    ///
    /// A send from Drafts names every copy its compose session held (#1071);
    /// whichever of them this list loaded is the row on screen -- the first
    /// in list order, should it hold more than one -- so that's the one the
    /// advance walks from. The rest go first: they're stale copies of the
    /// same draft, and leaving one in place would let the advance walk onto
    /// a row that's about to disappear. The advance target is worked out
    /// before the row goes, since every advance policy walks from its index.
    func applyRemoval(of refs: [MessageRef], from origin: UUID?, advancing: Bool) {
        var seen = Set<MessageRef>()
        let named = refs.filter {
            (isSearchScope ? index(of: $0) != nil : $0.folder == folder.path) && seen.insert($0).inserted
        }
        guard !named.isEmpty else { return }
        let current = envelopes.first { seen.contains(rowRef(for: $0)) }
        let currentRef = current.map(rowRef(for:))
        // Where each row was before any of them left, for a revert.
        var before: [MessageRef: Int] = [:]
        for ref in named { before[ref] = index(of: ref) }
        for ref in named where ref != currentRef {
            pruneEnvelope(ref, from: before[ref])
        }
        let next = current.flatMap { advanceTarget(after: $0, following: preferences.disposeAdvance) }
        if let currentRef {
            pruneEnvelope(currentRef, from: before[currentRef])
        }
        selectionReactions.append(ListSelectionReaction(
            kind: .removal, rows: seen, target: next.map(rowRef(for:)), origin: origin, advances: advancing
        ))
    }

    /// Swaps this list -- and whatever reader it is driving -- from the
    /// Drafts copies a compose session just retired onto the one that
    /// survived.
    ///
    /// The prune is the easy half. The half that matters is the selection:
    /// the reader Save Draft returns to still holds the retired copy's
    /// fetched body, and Edit Draft from there seeds the pre-edit content
    /// and pins the send's discard to an expunged UID, so the edit is
    /// dropped and the saved copy orphaned (#1078). Re-pointing rebuilds
    /// the reader against the survivor (the detail column is keyed on the
    /// UID), which re-fetches and shows what was actually saved.
    ///
    /// The refresh comes first because the survivor landed under a UID this
    /// list has never seen. Nothing else surfaces it promptly: the watcher
    /// on an open folder has no real IDLE behind it, so it re-reads
    /// `folderStatus` every 30 s and the row arrives somewhere in that
    /// window (measured at t+5 s and t+32 s on two runs -- #1083).
    ///
    /// A first save is that refresh and nothing else: no retired UID to
    /// prune, and `DraftReplacementPolicy.resolve` reads an empty chain as
    /// `.ignore`, so whatever the user was reading is left where it was. The
    /// search surface acts only when it lists one of the retired copies, so
    /// a draft saved while results show doesn't re-run the search.
    func applyDraftReplacement(_ replacement: DraftReplacement, in folderPath: String, from origin: UUID?) {
        let retired = replacement.retiredUIDs.map { MessageRef(folder: folderPath, uid: $0) }
        if isSearchScope {
            guard retired.contains(where: { index(of: $0) != nil }) else { return }
        } else {
            guard folder.path == folderPath else { return }
        }
        for ref in retired {
            pruneEnvelope(ref)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refresh()
            let loadedUIDs = envelopes.map(rowRef(for:)).filter { $0.folder == folderPath }.map(\.uid)
            selectionReactions.append(ListSelectionReaction(
                kind: .draftReplacement(replacement, loadedUIDs: loadedUIDs),
                rows: Set(retired), target: nil, origin: origin
            ))
        }
    }
}
