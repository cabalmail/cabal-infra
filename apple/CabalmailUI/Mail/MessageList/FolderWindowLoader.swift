import Foundation
import Observation
import CabalmailKit

/// What a folder window asks of the list showing it. Held weakly.
@MainActor
protocol FolderWindowHost: AnyObject {
    /// A search's rows are showing in place of the window's.
    var isSearchActive: Bool { get }
    /// Select mode is on with rows picked; a re-read mustn't reshuffle them.
    var isBuildingBulkSelection: Bool { get }
    /// The list's one error line. The window writes it and never reads it.
    var errorMessage: String? { get set }
}

/// What a folder window is known to line up with on the server, and the
/// state of any re-read that realigns it (`WindowReconciler`).
struct WindowAlignment {
    /// Nil while nothing proves where the loaded rows sit on the server: a
    /// window hydrated from the snapshot, or one just reset.
    var anchor: WindowAnchor?
    /// A window re-read is in flight; `ensureLoaded` starts no page meanwhile.
    var isReconciling = false
    /// Moved whenever the rows on screen are replaced or reset, or a search
    /// starts or installs its results. Every page load, the bottom prefetch
    /// and each await of a refresh pass compare it after the await, and drop
    /// what they brought when it moved.
    var generation = 0
    /// The viewport may show positions with no rows: a re-read replaced the
    /// rows without covering everything the list is showing, or a search
    /// stood the window's loads down and then didn't take the list over.
    /// What it lacks loads once `isLoading` falls.
    var needsSettleLoad = false
}

/// A folder list's window onto its folder: the rows loaded from it, where
/// they sit in the folder's sorted order, and every load that fills them.
///
/// On open, `STATUS` the folder for its message count, then fetch the top
/// page via `topEnvelopes`. Older pages load as the user scrolls, through
/// positional `envelopes(offset:limit:)` calls against the paginated
/// `/list_messages` (large-mailbox plan Layer 3.1). Where the window ends
/// against the STATUS total, and whether a page there came back empty,
/// decide `hasMore`, so sparse folders don't dead-end (Layer 3.3). The
/// envelope cache stores the top of the window keyed by `UIDVALIDITY`, so a
/// reopen is instant while the refresh runs in the background.
///
/// The behaviour lives in four engines built on each use, which hold
/// nothing but this window: `WindowPager` (paging and the bottom prefetch),
/// `WindowRefresher` (the single-flight refresh, the reset and the sort),
/// `WindowReconciler` (the re-read) and `WindowSnapshot` (what the folder
/// keeps for the next launch). A search the list runs over this folder
/// holds `isLoading` and stands the loads down
/// (`MessageListViewModel.runSearch`); its rows live in the list's
/// `MailSearchSession`, so `envelopes` only ever holds this folder's rows.
@Observable
@MainActor
final class FolderWindowLoader {
    let folder: Folder
    let client: CabalmailClient
    /// The session's shared mail state: the counts this window's STATUS
    /// sets, and the record of writes in flight its merges honour.
    let mailStore: MailSessionStore
    /// The list showing this window.
    @ObservationIgnored weak var host: (any FolderWindowHost)?

    /// Top-page size, small for a fast first paint on a cold folder; also
    /// the size up to which a top page is authoritative over the window.
    let pageSize: UInt32 = 50
    /// Older pages use a larger size: each /list_envelopes round trip carries
    /// fixed IMAP connect/SELECT overhead, so bigger pages mean steadier
    /// deep scrolling. Capped server-side by helper.py MAX_PAGE_SIZE (250).
    let loadMorePageSize: UInt32 = 200
    /// Most rows kept loaded. Trimming the scrolled-past side past this keeps
    /// SwiftUI's per-update cost bounded (its O(n) ForEach diff and the
    /// view's O(n) filter) while holding the viewport, the runway below it
    /// and a scroll-back buffer above.
    let windowCap = 600
    /// How near an edge a row may appear before the next page loads. It has
    /// to exceed the rows scrolled past during one page fetch, so it scales
    /// with `loadMorePageSize`: a little over one page keeps a page of runway.
    let prefetchDistance = 250

    /// A contiguous run [windowStart, windowStart + count) of the folder's
    /// sorted rows.
    var envelopes: [Envelope] = []
    /// A refresh, a reset, or a search the list runs over this folder is in
    /// flight: the gate that keeps page loads out meanwhile, and half of the
    /// list's `isLoading`. It falls only once the last of them has returned
    /// (`holdLoading()`), so an overlapping one can't lower it for another.
    private(set) var isLoading = false
    /// A page below the window is loading.
    var isLoadingMore = false
    /// A page above the window is loading. No spinner (one at the top would
    /// shift the scroll); it keeps a page below from overlapping it.
    var isLoadingPrevious = false
    /// A jump's window (a scrollbar drag into an unloaded region) is loading.
    var isLoadingWindow = false
    /// The order the rows load and show in, server-side and here.
    var sortCriterion: SortCriterion = .default
    /// The folder's UIDVALIDITY, from the last STATUS or the snapshot; nil
    /// until one answers.
    var uidValidity: UInt32?
    /// The folder's message count from the last STATUS: the All count and
    /// the list's length.
    var totalMessages: UInt32 = 0 {
        // A folder whose count moved may hold rows below the window again.
        didSet { if totalMessages != oldValue { hasMore = true } }
    }
    /// The All pill's count until a STATUS answers this session: the folder
    /// total last saved. Kept apart from `totalMessages`, which also sizes
    /// the list, where a total nothing can load offline would draw
    /// placeholder rows.
    var savedMessageCount: Int?
    /// Whether a page below the window may still hold rows; `ensureLoaded`
    /// asks for one only while it is set. A page that comes back empty clears
    /// it, so a STATUS that over-counts isn't asked for the same empty page by
    /// every row that appears (#1823). Only a change to `totalMessages`, a
    /// move of the window's end, or a reset sets it again
    /// (`recomputeHasMore(windowEndBefore:)`).
    var hasMore = true
    /// The absolute position of `envelopes[0]`, so page offsets are absolute.
    var windowStart: UInt32 = 0
    /// The window no longer starts at the folder's top, which stops the
    /// top-page refresh and the snapshot write (both assume one that does).
    var hasTrimmedFront = false
    @ObservationIgnored var alignment = WindowAlignment()
    /// The refresh passes in flight and the refreshes parked on them.
    @ObservationIgnored var refreshFlight = RefreshFlight()
    /// The refreshes, resets and searches holding `isLoading` up.
    @ObservationIgnored private var loadingHolds = 0

    /// The page loads, each owned here so it outlives the row `.task` that
    /// asked for it; `cancelTasks()` stops them when the list goes away.
    var loadMoreTask: Task<Void, Never>?
    var loadPrevTask: Task<Void, Never>?
    var loadWindowTask: Task<Void, Never>?
    /// The debounced snapshot write (`WindowSnapshot.schedulePersist`).
    var persistTask: Task<Void, Never>?
    /// The debounced load of where the list settled after a scroll or jump.
    var keyScrollTask: Task<Void, Never>?
    /// Absolute indices of the rows the list is rendering, counted, since a
    /// replaced row is one leaving its index and another arriving at it in
    /// no promised order. Not observed: it churns with every scroll.
    @ObservationIgnored var visibleRowIndices: [Int: Int] = [:]
    /// The folder's last page, staged off to the side so the first jump to
    /// the bottom costs no round trip (`WindowPager`). Not observed.
    @ObservationIgnored var bottomPrefetch: BottomPrefetch?
    @ObservationIgnored var bottomPrefetchTask: Task<Void, Never>?

    init(folder: Folder, client: CabalmailClient, mailStore: MailSessionStore) {
        self.folder = folder
        self.client = client
        self.mailStore = mailStore
    }

    var pager: WindowPager { WindowPager(window: self) }
    var refresher: WindowRefresher { WindowRefresher(window: self) }
    var reconciler: WindowReconciler { WindowReconciler(window: self) }
    var snapshot: WindowSnapshot { WindowSnapshot(window: self) }

    var isSearchActive: Bool { host?.isSearchActive ?? false }
    var isBuildingBulkSelection: Bool { host?.isBuildingBulkSelection ?? false }

    /// The comparator for `sort(by:)` under the active `sortCriterion`.
    var envelopeOrder: (Envelope, Envelope) -> Bool { EnvelopeOrder(sortCriterion).precedes }

    /// The removals in flight that touch this window: its folder's, from any
    /// writer. Paging waits while it is non-empty, since a removal moves
    /// every row below it up a place.
    var pendingRemovedRefs: Set<MessageRef> {
        mailStore.shields.pendingMoveRefs.filter { $0.folder == folder.path }
    }

    /// The identity of `envelope`'s row. Every row this window loads carries
    /// its folder (`placedInFolder(_:)`); one that doesn't is taken to be
    /// this folder's.
    func rowRef(for envelope: Envelope) -> MessageRef {
        envelope.ref(defaultFolder: folder.path, uidValidity: uidValidity)
    }

    /// `fetched`, a page of this folder's rows, placed in this folder so each
    /// row names its own message. Every path that brings folder rows into
    /// `envelopes` goes through this (or through `shieldFetched`).
    func placedInFolder(_ fetched: [Envelope]) -> [Envelope] {
        fetched.map { $0.folder == nil ? $0.inFolder(folder.path) : $0 }
    }

    private func index(of ref: MessageRef) -> Int? {
        envelopes.firstIndex { rowRef(for: $0) == ref }
    }

    private func envelope(for ref: MessageRef) -> Envelope? {
        index(of: ref).map { envelopes[$0] }
    }

    /// The row at an absolute folder position, or nil when the window doesn't
    /// hold it (the row then draws a placeholder). The list's `ForEach` spans
    /// the folder's whole stable position range and looks each row up here.
    func envelope(at absoluteIndex: Int) -> Envelope? {
        let local = absoluteIndex - Int(windowStart)
        guard local >= 0, local < envelopes.count else { return nil }
        return envelopes[local]
    }

    /// `fetched` as far as the writes in flight allow: a row being removed by
    /// anyone stays gone until the removal resolves, and a message the server
    /// confirmed gone stays gone for good (IMAP never reuses a UID in a
    /// mailbox, so a fetch still carrying it was answered before the move
    /// landed); a row with a flag write in flight keeps the flags it shows.
    /// The memory merge and the snapshot write both go through this, so the
    /// two agree.
    func shieldFetched(_ fetched: [Envelope]) -> [Envelope] {
        let confirmedGone = mailStore.shields.confirmedRemovalRefs(folderPath: folder.path)
        return placedInFolder(fetched).compactMap { fetchedEnvelope in
            let ref = rowRef(for: fetchedEnvelope)
            if mailStore.shields.isRemoving(ref) || confirmedGone.contains(ref) { return nil }
            if mailStore.shields.isWritingFlags(ref), let local = envelope(for: ref) {
                return fetchedEnvelope.withFlags(local.flags)
            }
            return fetchedEnvelope
        }
    }

    /// Folds a fetch into the rows, shielded (`shieldFetched`), and re-sorts
    /// them under the active order.
    func mergeFetched(_ fetched: [Envelope]) {
        var byRef: [MessageRef: Envelope] = Dictionary(
            uniqueKeysWithValues: envelopes.map { (rowRef(for: $0), $0) }
        )
        for envelope in shieldFetched(fetched) {
            byRef[rowRef(for: envelope)] = envelope
        }
        envelopes = byRef.values.sorted(by: envelopeOrder)
    }

    /// A row at this absolute index appeared: the list scrolled, so (re)arm
    /// the load of where it settles, which covers rows that landed on
    /// placeholders while a page load still held the gate.
    func noteRowVisible(_ index: Int) {
        visibleRowIndices[index, default: 0] += 1
        scheduleEnsureLoaded()
    }

    /// A row at this absolute index left; the index stays rendered while
    /// another row there still reports in.
    func noteRowHidden(_ index: Int) {
        guard let rows = visibleRowIndices[index] else { return }
        visibleRowIndices[index] = rows > 1 ? rows - 1 : nil
    }

    /// The lowest and highest absolute index the list is rendering, or nil
    /// before any row has reported in.
    var firstVisibleRow: Int? { visibleRowIndices.keys.min() }
    var lastVisibleRow: Int? { visibleRowIndices.keys.max() }

    /// Takes a STATUS reply's counts: `totalMessages` here, and the Unread and
    /// Flagged counts in the mail store, where the sidebar reads them too
    /// (`MailSessionStore.takeStatus`). Returns the server's own total, the
    /// numbering the top page is addressed in.
    ///
    /// A reply that may predate a removal this client already applied
    /// (`mayPredateRemoval`) would count the departed message again, so it
    /// may lower the total but not raise it. `askedAt` is when the STATUS was
    /// asked for: a flag write in flight then, or since, may be missing from
    /// it, so the store moves the Unread and Flagged counts only the way
    /// those writes move them (#1880).
    func applyStatusCounts(
        _ status: FolderStatus,
        mayPredateRemoval: Bool = false,
        askedAt: ContinuousClock.Instant = .now
    ) -> UInt32 {
        let serverMessages = UInt32(max(0, status.messages ?? 0))
        var messages = serverMessages
        if mayPredateRemoval {
            messages = min(messages, totalMessages)
        }
        // A changed folder size shifts every absolute index, so a staged
        // bottom page is no longer aligned (`performLoadWindow` also checks
        // its stamp, for the gap between a write and the STATUS showing it).
        if messages != totalMessages { invalidateBottomPrefetch() }
        totalMessages = messages
        savedMessageCount = nil
        if mayPredateRemoval {
            mailStore.takeStatus(
                status, predatingRemovalIn: folder.path, askedAt: askedAt,
                shownTotal: Int(totalMessages), fetchedThrough: client
            )
        } else {
            mailStore.takeStatus(status, folderPath: folder.path, askedAt: askedAt, fetchedThrough: client)
        }
        return serverMessages
    }

    /// True when a STATUS or fetch issued at `startedAt` may have been
    /// answered from this folder as it stood before a removal the list has
    /// already applied: one is still in flight, from any writer, or the
    /// server confirmed one after `startedAt`.
    func removalMayPostdate(_ startedAt: ContinuousClock.Instant) -> Bool {
        !pendingRemovedRefs.isEmpty
            || mailStore.shields.removalConfirmed(folderPath: folder.path, after: startedAt)
    }

    /// Moves the total by a removal this list made itself (or its revert),
    /// and the anchor with it, so the next STATUS doesn't read the removal as
    /// a change made elsewhere (`WindowAnchor`). Clamped at zero.
    func adjustTotal(by delta: Int) {
        totalMessages = UInt32(max(0, Int(totalMessages) + delta))
        if let anchor = alignment.anchor {
            alignment.anchor?.total = UInt32(max(0, Int(anchor.total) + delta))
        }
    }

    /// Drops any staged bottom page and cancels a fill in flight: on every
    /// reset, and whenever the folder's size or rows move under it.
    func invalidateBottomPrefetch() {
        bottomPrefetchTask?.cancel()
        bottomPrefetchTask = nil
        bottomPrefetch = nil
    }

    /// Starts the window over at the folder's top, on every path that wipes
    /// the rows (hard reload, sort change, search clear, UIDVALIDITY change).
    func resetWindow() {
        standDownWindowLoads()
        windowStart = 0
        hasTrimmedFront = false
        hasMore = true
        forgetWindowAnchor()
    }

    /// `hasMore` from where the window ends now, `windowEndBefore` being where
    /// it ended before the change. An empty page's verdict stands while the
    /// window's end hasn't moved (#1823); a change in `totalMessages` lifts it
    /// through its didSet, and a reset through `resetWindow()`.
    func recomputeHasMore(windowEndBefore: UInt32) {
        let windowEnd = windowStart + UInt32(envelopes.count)
        hasMore = windowEnd < totalMessages && (hasMore || windowEnd != windowEndBefore)
    }

    /// Stands down every load addressed to the rows on screen: the page
    /// loads are cancelled, the staged bottom window dropped, and the
    /// generation moved, so a page or a refresh pass that lands anyway drops
    /// what it brought (#1870). Every reset runs it, and so does a search, as
    /// it starts and as its rows replace the folder's.
    func standDownWindowLoads() {
        loadMoreTask?.cancel()
        loadPrevTask?.cancel()
        loadWindowTask?.cancel()
        invalidateBottomPrefetch()
        alignment.generation += 1
    }

    /// After a search that stood the window's loads down and then didn't take
    /// the list over (it failed, was cancelled, or another overtook it): what
    /// the viewport shows loads once `isLoading` falls, and the bottom window
    /// is staged again.
    func resumeWindowLoads() {
        alignment.needsSettleLoad = true
        scheduleBottomPrefetch()
    }

    /// The window no longer lines up with anything known: hydrated from the
    /// snapshot, or reset. The next trustworthy refresh decides afresh.
    func forgetWindowAnchor() {
        alignment.anchor = nil
        alignment.generation += 1
    }

    /// Holds `isLoading` up for a refresh, a reset or a search until the
    /// matching `releaseLoading()`. The last release lowers it, and loads
    /// what the viewport shows without rows (`needsSettleLoad`).
    func holdLoading() {
        loadingHolds += 1
        isLoading = true
    }

    func releaseLoading() {
        loadingHolds -= 1
        guard loadingHolds == 0 else { return }
        isLoading = false
        if alignment.needsSettleLoad {
            alignment.needsSettleLoad = false
            scheduleEnsureLoaded()
        }
    }

    /// Stops every task the window owns, when the list leaves the screen: the
    /// page loads, the snapshot write, the settle load and the bottom fill.
    /// A staged bottom page stays for the list's return.
    func cancelTasks() {
        loadMoreTask?.cancel()
        loadMoreTask = nil
        loadPrevTask?.cancel()
        loadPrevTask = nil
        loadWindowTask?.cancel()
        loadWindowTask = nil
        persistTask?.cancel()
        persistTask = nil
        keyScrollTask?.cancel()
        keyScrollTask = nil
        bottomPrefetchTask?.cancel()
        bottomPrefetchTask = nil
    }

    func ensureLoaded(around absoluteIndex: Int) { pager.ensureLoaded(around: absoluteIndex) }
    func scheduleEnsureLoaded() { pager.scheduleEnsureLoaded() }
    func scheduleBottomPrefetch() { pager.scheduleBottomPrefetch() }

    /// The folder's refresh (`WindowRefresher`); the list routes a refresh
    /// here unless a search is showing.
    func refresh(prefetched: PrefetchedStatus?, startingOver: Bool) async {
        await refresher.refresh(prefetched: prefetched, startingOver: startingOver)
    }

    func resetForHardReload() async -> PrefetchedStatus? { await refresher.resetForHardReload() }
    func refreshCounts(prefetched: PrefetchedStatus?) async { await refresher.refreshCounts(prefetched: prefetched) }
    func setSort(_ criterion: SortCriterion) async { await refresher.setSort(criterion) }
    func hydrateFromCache() async { await snapshot.hydrateFromCache() }
    func seedSavedCounts() async { await snapshot.seedSavedCounts() }
}
