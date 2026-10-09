import Foundation
import Observation
import CabalmailKit

/// What a search asks of the list showing it. Held weakly.
@MainActor
protocol MailSearchHost: AnyObject {
    /// A refresh, a reset or a search is out on the list; a next page waits
    /// for it.
    var isLoading: Bool { get }
    /// The list's one error line. A search writes it and never reads it.
    var errorMessage: String? { get set }
    /// The identity the list gives `envelope`'s row.
    func rowRef(for envelope: Envelope) -> MessageRef
    /// The results are about to replace the rows on screen: whatever is still
    /// loading into those rows stands down first (#1870). Called in the
    /// main-actor step the results land in.
    func searchWillShowResults()
}

/// One list's structured search (`/search_envelopes`): the query and filters
/// being built, the term last sent, and the search in effect -- its rows, the
/// banner's numbers and the cursor for the next page.
///
/// A folder list's Unread and Flagged pills are searches narrowed to its
/// folder; on the global search surface every search is one, and its rows are
/// all the list shows. Each row carries its own folder (`SearchedEnvelope`
/// places it), so a write on a row reaches that row's mailbox. The search
/// knows no folder window: the list stands its window down around a run
/// (`MessageListViewModel.runSearch`).
@Observable
@MainActor
final class MailSearchSession {
    /// Per-request page size: a run's first page (and a re-run's chunked
    /// re-walk) and each next page. No request asks the Lambda for the whole
    /// match set (Layer 3.2 of the large-mailbox-hardening plan); depth comes
    /// from scroll-driven paging. Mirrors the folder view's page size and the
    /// Lambda's DEFAULT_LIMIT.
    static let pageSize = 50

    let client: CabalmailClient
    /// The folder list's own folder, which its pills narrow to; nil on the
    /// global search surface.
    let listFolder: Folder?
    /// The list showing this search.
    @ObservationIgnored weak var host: (any MailSearchHost)?

    /// The free-text term as typed. Sent, with `filters`, by the next run.
    var query = ""
    /// Structured filter form state -- mirrors the React filter panel.
    var filters = MessageSearchFilters()
    /// The folder the search surface's "This folder only" narrows to: the
    /// wide layout's sidebar selection, fed in through
    /// `MessageListViewModel.setSearchAnchor(_:)`. Unused on a folder list,
    /// which narrows to `listFolder`; see `folder`.
    var anchor: Folder?
    /// The trimmed term the latest run was sent with. Distinct from `query`,
    /// which tracks the field as the user types: search is submit-driven, so
    /// the two diverge for every keystroke between typing and Return, and
    /// that gap is what tells a pending query from an exhausted one.
    private(set) var submittedQuery = ""
    /// A search is the list's mode: its banner shows, a refresh re-runs it,
    /// and the folder window's loads stand down. Set as a run's results land;
    /// cleared by `clear()`.
    var isActive = false
    /// The rows on screen are `rows`. Set and cleared with `isActive` by
    /// every path the app takes; kept apart so that marking a search active
    /// by hand moves no rows.
    private(set) var showsResults = false
    /// The results, each placed in its own folder.
    var rows: [Envelope] = []
    /// Search-banner metadata. All zero when no search is active.
    private(set) var totalEstimate = 0
    private(set) var truncated = false
    private(set) var foldersSearched: [String] = []
    /// Opaque next-page cursor; nil = every match loaded (or no search
    /// active). Cleared as every run starts, so a next page still out finds
    /// it moved and drops what it brought.
    private(set) var nextCursor: String?
    /// A run is out. It falls only once the last run has returned.
    private(set) var isLoading = false
    @ObservationIgnored private var runsOut = 0
    /// A next page is in flight: guards re-entry and drives the list's tail
    /// spinner.
    private(set) var isLoadingMore = false
    /// The next page's fetch, owned here so it outlives the row `.task` that
    /// asked for it.
    private(set) var loadMoreTask: Task<Void, Never>?

    init(client: CabalmailClient, listFolder: Folder?) {
        self.client = client
        self.listFolder = listFolder
    }

    /// The folder "This folder only" narrows to: a folder list's own, the
    /// search surface's anchor, or nil where nothing feeds one in (the
    /// iPhone / visionOS `SearchView`), which is what hides the toggle there
    /// (#1510).
    var folder: Folder? { listFolder ?? anchor }

    /// Runs `text` with the filters as they stand, `depth` rows deep, fetched
    /// in `pageSize` chunks by walking the cursor (Layer 3.2 of the
    /// large-mailbox-hardening plan). A clear or a newer submission during
    /// the fetch owns the list now, so this run then lands nothing, its error
    /// included (#1536). A re-run (`rerun`) whose task was cancelled keeps
    /// the cursor for the rows it leaves (#1816).
    func run(_ text: String, depth: Int, rerun: Bool) async {
        // Recorded at submit time, not on success: the question the
        // placeholder asks is "has this term been sent yet", which a failed
        // request answers just as much as a successful one.
        submittedQuery = text
        // Invalidate the old cursor before the await: a next page that's
        // mid-flight checks its cursor is still current before appending, so
        // this reset makes it drop a page that belongs to the outgoing result
        // set.
        let priorCursor = nextCursor
        nextCursor = nil
        runsOut += 1
        isLoading = true
        defer {
            runsOut -= 1
            isLoading = runsOut > 0
        }
        // Snapshotted for the staleness check below: the filters this request
        // asked with, not whatever they hold when it answers.
        let filters = self.filters
        do {
            let result = try await client.imapClient.searchEnvelopesChunked(
                buildQuery(text: text, filters: filters),
                pageSize: Self.pageSize,
                maxResults: depth
            )
            guard submittedQuery == text, self.filters == filters else { return }
            host?.searchWillShowResults()
            rows = distinctRows(result.envelopes, after: [])
            showsResults = true
            totalEstimate = result.totalEstimate
            truncated = result.truncated
            foldersSearched = result.foldersSearched
            nextCursor = result.nextCursor
            isActive = true
            host?.errorMessage = nil
        } catch {
            // Same staleness rule: an ended search's failure is not worth a
            // banner over the folder view the user is now looking at.
            guard submittedQuery == text, self.filters == filters else { return }
            // Nor is a re-run's whose task was cancelled (#1816); its rows
            // are still the loaded ones, so they keep their cursor.
            guard !Task.isCancelled else {
                if rerun { nextCursor = priorCursor }
                return
            }
            host?.errorMessage = error.localizedDescription
        }
    }

    /// View-facing trigger for the next page. Hops onto a task this search
    /// owns, so the row `.task` that fired it can be cancelled by scrolling
    /// without cancelling the fetch mid-flight -- the folder window's
    /// `loadMoreTask` pattern, and the same reason: a propagated cancellation
    /// would surface as a spurious error. The guards make redundant kicks
    /// free.
    func requestMore() {
        guard isActive, !listIsLoading, !isLoadingMore, nextCursor != nil else { return }
        loadMoreTask = Task { [weak self] in await self?.loadMore() }
    }

    /// Fetches the next page of the active search and appends it -- the
    /// scroll-driven leg of search paging, triggered (via `requestMore`) by
    /// the list nearing the end of the loaded matches and by the visible rows
    /// emptying (a pill page the user has fully dealt with must still pull
    /// the next). No-op unless a search is active with a cursor and nothing
    /// else is fetching.
    func loadMore() async {
        guard isActive, !listIsLoading, !isLoadingMore, let cursor = nextCursor else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let query = buildQuery(text: submittedQuery, filters: filters)
            let page = try await client.imapClient.searchEnvelopes(
                query.page(limit: Self.pageSize, cursor: cursor)
            )
            // A clear or a fresh run during the await owns the rows now; this
            // page belongs to the outgoing result set.
            guard isActive, nextCursor == cursor else { return }
            appendPage(page)
            host?.errorMessage = nil
        } catch {
            guard isActive, nextCursor == cursor else { return }
            host?.errorMessage = error.localizedDescription
        }
    }

    /// Ends the search: the field, the term sent, the filters, the mode, the
    /// banner, the cursor and the rows. A run or a next page still out finds
    /// itself stale and lands nothing.
    func clear() {
        query = ""
        submittedQuery = ""
        filters = MessageSearchFilters()
        isActive = false
        showsResults = false
        totalEstimate = 0
        truncated = false
        foldersSearched = []
        nextCursor = nil
        rows.removeAll()
    }

    /// The list's loading, which a next page waits for (a refresh or a reset
    /// of the folder counts as well as a run); this search's own once the
    /// list has gone.
    private var listIsLoading: Bool { host?.isLoading ?? isLoading }

    /// Appends one page, dropping rows already loaded: the cursor is
    /// date-based, so a page boundary shifting under mailbox churn can
    /// re-deliver a row from the previous page, and a duplicate would draw as
    /// a repeated row.
    private func appendPage(_ page: SearchResult) {
        rows.append(contentsOf: distinctRows(page.envelopes, after: rows))
        totalEstimate = page.totalEstimate
        truncated = truncated || page.truncated
        nextCursor = page.nextCursor
    }

    /// `found`'s envelopes, each placed in its own folder, minus any message
    /// `loaded` or an earlier row already holds. A message is one ref
    /// (folder and UID), however many pages deliver it, and the list draws
    /// each ref as one row (`MessageRowIdentity`).
    private func distinctRows(_ found: [SearchedEnvelope], after loaded: [Envelope]) -> [Envelope] {
        var seen = Set(loaded.compactMap { host?.rowRef(for: $0) })
        return found.filter { seen.insert($0.ref).inserted }.map(\.envelope)
    }

    private func buildQuery(text: String, filters: MessageSearchFilters) -> SearchQuery {
        SearchQuery(
            folder: filters.thisFolderOnly ? folder?.path : nil,
            text: text.isEmpty ? nil : text,
            from: filters.from.isEmpty ? nil : filters.from,
            to: filters.to.isEmpty ? nil : filters.to,
            subject: filters.subject.isEmpty ? nil : filters.subject,
            since: filters.since,
            before: filters.before,
            unread: filters.unread,
            flagged: filters.flagged,
            hasAttachment: filters.hasAttachment
            // `limit` and `cursor` are owned by the fetch paths: `run`'s
            // chunked walk and `loadMore`'s single page both fill them per
            // request via `page(limit:cursor:)`.
        )
    }
}
