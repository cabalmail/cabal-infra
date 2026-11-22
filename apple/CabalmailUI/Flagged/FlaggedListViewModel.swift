import Foundation
import Observation
import CabalmailKit

/// Messages that left the Flagged list because they left their folders, for
/// the view to close a reader that has one of them open.
struct FlaggedRemovals: Equatable {
    var tick = 0
    var refs: Set<MessageRef> = []
}

/// Where a restored window's open item stands: its row, once the rows that
/// hold it have loaded; not yet, while a half is still loading; or gone,
/// once both have answered without it (it is no longer flagged, or it is
/// past the first page).
enum FlaggedAwaitedItem: Equatable {
    case found(FlaggedRow)
    case waiting
    case gone
}

/// Backs the Flagged view (`docs/1.x/cross-media-ux-plan.md`, Phase 5):
/// flagged messages from the mail source and flagged feed items from the
/// device's store, as one list (`FlaggedList`).
///
/// One per main window, held by its `SceneNavigator` for as long as the
/// window is on the view, so a reader pushed and popped on iPhone, the
/// view's other door and a change of layout shell all find the rows and the
/// pick as they were, with no second search.
///
/// The feed half is read first, since it is local, and held behind the
/// horizon until the first page of mail lands or fails. A refresh keeps the
/// messages on screen until its first page lands, so one that fails loses
/// nothing. What each half holds, and what a page landing or a row leaving
/// does to it, is `FlaggedMailHalf`'s and `FlaggedFeedHalf`'s.
///
/// A row whose flag is cleared so that the pick no longer finds it leaves
/// at once, message or feed item. A reader that has it open is not this
/// list's to close, and setting the flag again there brings the row back.
///
/// A message's writes go through the mail store's mutation service with
/// the row's own ref, so they reach the row's own folder, and every other
/// list and reader hears them; this list hears theirs (`MailEvents`).
@Observable
@MainActor
final class FlaggedListViewModel {
    /// What the view is narrowed to. Any flag unless the user picks one,
    /// for the visit.
    private(set) var criterion: FlagCriterion = .any
    /// What the list shows.
    private(set) var page = FlaggedPage(rows: [], cutoff: FlaggedList.nothingYet, next: .mail, heldBack: 0)
    private(set) var mailLoading = false
    private(set) var isRefreshing = false
    /// A write that failed, in words.
    var errorMessage: String?
    /// Counts the lists that began afresh (the open, a pick), so the view
    /// scrolls to the top.
    private(set) var listEpoch = 0
    private(set) var removals = FlaggedRemovals()
    /// The mail request in flight; a pick or a refresh replaces it.
    private(set) var mailTask: Task<Void, Never>?

    private let source: any FlaggedMailSource
    private let client: CabalmailClient
    private let feedStore: FlaggedFeedStore
    private let mailStore: MailSessionStore
    private let preferences: Preferences

    private var mail = FlaggedMailHalf()
    private var feed = FlaggedFeedHalf()
    private var feedReading = false
    private var started = false
    /// Whether the row that asks for more is on screen: a page that moves
    /// the horizon without filling the screen leaves it there, and nothing
    /// would ask again.
    private var footerVisible = false

    init(
        client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore,
        source: (any FlaggedMailSource)? = nil, store: RssStore? = nil, engine: RssSyncEngine? = nil
    ) {
        self.client = client
        self.preferences = preferences
        self.mailStore = mailStore
        self.source = source ?? SearchFlaggedMailSource(imap: client.imapClient)
        feedStore = FlaggedFeedStore(store: store ?? client.rssStore, engine: engine ?? client.rssSync)
        mailStore.events.subscribe(self)
    }

    // MARK: - What the view reads

    var mailFailure: FlaggedMailFailure? { mail.failure }
    /// The failure in words, for the line above the list.
    var mailFailureMessage: String? { mail.failureMessage }
    /// The source stopped at its cap: some flagged messages are not listed,
    /// and not only old ones.
    var truncated: Bool { mail.truncated }
    /// Whether the feed half has been read at least once for this pick.
    var feedLoaded: Bool { feed.loaded }
    /// Feed items with a queued (not yet pushed) change, for the row mark.
    var pendingIDs: Set<String> { feed.pendingIDs }

    /// Whether everything there is has been asked for and nothing matched.
    var isEmpty: Bool {
        feed.loaded && !mailLoading && mail.failure == nil && page.rows.isEmpty && page.next == nil
    }

    /// How many items the pick finds: the mail half's count plus the feed
    /// store's. Nil until the mail half has answered.
    var count: Int? {
        mail.count(matching: criterion).map { $0 + (feed.count ?? 0) }
    }

    /// The pill above the list, or nil while the built-in flag is the only
    /// flag there is to pick (`FlagFilterMenuPolicy.flaggedViewPill`).
    var pill: FlagFilterPillModel? {
        FlagFilterMenuPolicy.flaggedViewPill(palette: preferences.flagPalette, current: criterion, count: count)
    }

    var flagPalette: [FlagPaletteEntry] { preferences.flagPalette }

    /// The flag the one-press controls set and clear on a row: the first
    /// entry of Settings > Flags, as on both media's own lists.
    var defaultFlag: FlagToggle { FlagToggle.defaultFlag(in: preferences.flagPalette) }

    var swipeLeading: FeedSwipeAction { preferences.rssSwipeLeading }
    var swipeTrailing: FeedSwipeAction { preferences.rssSwipeTrailing }

    /// The feed a row belongs to: its title, else the article's host.
    func feedName(for item: RssItem) -> String {
        FeedItemLabels.feedName(for: item, titles: feed.titles)
    }

    /// The row for `ref` among everything loaded, shown or held back.
    func row(for ref: ItemRef) -> FlaggedRow? {
        switch ref {
        case .mail(let message):
            return mail.row(for: message).map { .mail($0.envelope, $0.ref) }
        case .feed:
            return feed.items.first { $0.ref == ref }.map(FlaggedRow.feed)
        }
    }

    func awaited(_ ref: ItemRef) -> FlaggedAwaitedItem {
        if let row = row(for: ref) { return .found(row) }
        return mailLoading || !feed.loaded ? .waiting : .gone
    }

    // MARK: - Loading

    /// The view came up. The first time, both halves load; after that the
    /// rows are as they were.
    func start() {
        guard !started else { return }
        started = true
        Task { await readFeed() }
        loadMail(reset: true)
        Task { await syncFeeds() }
    }

    /// Pull to refresh: both halves again, keeping what is on screen until
    /// the new rows land.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        errorMessage = nil
        loadMail(reset: true)
        async let feeds: Void = syncFeeds()
        await mailTask?.value
        await feeds
    }

    /// Narrows the view to one flag, or back to any: a different list, so
    /// both halves start over. For the visit; nothing is stored.
    func pick(_ new: FlagCriterion) {
        guard new != criterion else { return }
        criterion = new
        mail = FlaggedMailHalf()
        feed = FlaggedFeedHalf()
        listEpoch += 1
        rebuild()
        Task { await readFeed() }
        loadMail(reset: true)
    }

    /// A row of the pill's menu.
    func choose(_ choice: FlagFilterChoice) {
        if let criterion = FlagFilterMenuPolicy.criterion(for: choice) { pick(criterion) }
    }

    /// The row that asks for more came on screen, or left it.
    func footer(isVisible: Bool) {
        footerVisible = isVisible
        if isVisible { loadMore() }
    }

    /// Loads whichever half the horizon is waiting on.
    func loadMore() {
        switch page.next {
        case .mail:
            guard !mailLoading, mail.failure == nil, mail.cursor != nil else { return }
            loadMail(reset: false)
        case .feed:
            Task { await readFeed(more: true) }
        case nil:
            break
        }
    }

    /// Retry on the line that says mail could not be had: the first page,
    /// or the one that failed.
    func retryMail() {
        guard !mailLoading else { return }
        loadMail(reset: mail.failure != .nextPage)
    }

    /// The connection came back: a mail half that failed is tried again,
    /// with no tap.
    func connectionReturned() {
        if mail.failure != nil { retryMail() }
    }

    /// Follows the feed store while the view is up, from a re-read: nothing
    /// followed it while no view was (a reader pushed over the list).
    func observe() async {
        guard let store = feedStore.store else { return }
        let changes = await store.changes()
        await readFeed()
        await FeedStoreChanges.follow(changes) { [weak self] _ in await self?.readFeed() }
    }

    private func loadMail(reset: Bool) {
        mailTask?.cancel()
        let asked = criterion
        let cursor = reset ? nil : mail.cursor
        mailLoading = true
        mail.beginLoad()
        mailTask = Task { [weak self, source] in
            let answer: Result<FlaggedMailPage, any Error>
            do {
                answer = .success(try await source.page(matching: asked, after: cursor))
            } catch {
                answer = .failure(error)
            }
            // A pick or a refresh made meanwhile asked for another list.
            guard !Task.isCancelled, let self, self.criterion == asked else { return }
            self.mailAnswered(answer, reset: reset)
        }
    }

    private func mailAnswered(_ answer: Result<FlaggedMailPage, any Error>, reset: Bool) {
        let shownBefore = reset ? 0 : shownMailCount
        mailLoading = false
        switch answer {
        case .success(let landed):
            mail.land(landed, reset: reset)
            rebuild()
            // A page that showed no new message (all of it one day, say)
            // leaves the asking row where it was, so nothing would ask again.
            if footerVisible || (page.next == .mail && shownMailCount == shownBefore) { loadMore() }
        case .failure(let error):
            mail.fail(error, reset: reset)
            rebuild()
        }
    }

    private var shownMailCount: Int {
        page.rows.filter { $0.ref.message != nil }.count
    }

    private func syncFeeds() async {
        await feedStore.sync()
        await readFeed()
    }

    /// Reads the feed half from the store (`FlaggedFeedHalf.query`).
    private func readFeed(more: Bool = false) async {
        guard feedStore.store != nil else {
            feed.landNothing()
            return rebuild()
        }
        if more {
            guard !feedReading, feed.hasMore else { return }
        }
        feedReading = true
        defer { feedReading = false }
        let asked = criterion
        // A pick made while the store was being read asked for another list.
        guard let read = await feedStore.read(feed.query(matching: asked, more: more)), criterion == asked
        else { return }
        feed.land(read, more: more)
        rebuild()
    }

    /// The list from everything loaded. Both halves are narrowed here as
    /// well as at their sources, so a row whose flag was just cleared
    /// leaves at once, ahead of the next read.
    private func rebuild() {
        page = FlaggedList.merge(
            mail: mail.matching(criterion), mailCutoff: mail.cutoff,
            feed: feed.matching(criterion), feedCutoff: feed.cutoff
        )
    }

    // MARK: - A message's row

    func toggleSeen(_ ref: MessageRef) async {
        await toggle(.seen, on: ref)
    }

    func toggleDefaultFlag(on ref: MessageRef) async {
        await toggle(defaultFlag.flag, on: ref)
    }

    /// Sets one flag on a message that lacks it and clears it on one that
    /// carries it, in the message's own folder. A refused write puts the
    /// row back as it was.
    func toggle(_ flag: Flag, on ref: MessageRef) async {
        guard let envelope = mail.row(for: ref)?.envelope else { return }
        let added = !envelope.flags.contains(flag)
        applyFlag(flag, added: added, to: [ref])
        let outcome = await mailStore.mutations.setFlag(
            flag, added: added, on: [ref], changing: [ref], by: .list(self, through: client)
        ).value
        guard outcome.failed.contains(ref) else { return }
        applyFlag(flag, added: !added, to: [ref])
        errorMessage = outcome.message
    }

    /// What the dispose affordances mean for the message `ref` names: the
    /// user's preference resolved against the row's own folder, not this
    /// view, which has none. Restore inside Archive, the plain move
    /// elsewhere.
    func disposeIntent(for ref: MessageRef) -> DisposeIntent {
        DisposeIntent.standard(preference: preferences.disposeAction, in: ref.folder)
    }

    /// Carries out `disposeIntent(for:)`: the row leaves at once, the move
    /// goes out from the row's own folder, and a refused one puts the row
    /// back. A dispose marks the message read as it moves, as everywhere; a
    /// restore carries its unread state with it.
    func dispose(_ ref: MessageRef) async {
        let intent = disposeIntent(for: ref)
        guard let destination = intent.destinationFolder else { return }
        await move(ref, to: destination, markingSeen: intent != .restore)
    }

    /// Moves the message `ref` names out of its own folder to
    /// `destination`: the Message menu's Move, and what a dispose comes to.
    /// The row leaves at once and a refused move puts it back. The message
    /// keeps its flag where it lands, under a number this list cannot know,
    /// so it is listed again from the next refresh.
    func move(_ ref: MessageRef, to destination: String, markingSeen: Bool = false) async {
        guard destination != ref.folder, let envelope = mail.row(for: ref)?.envelope else { return }
        // The row leaves before the first suspension, so a second move of
        // the same message finds no row and sends nothing.
        let wasUnread = !envelope.flags.contains(.seen)
        remove([ref])
        let outcome = await mailStore.mutations.remove(
            [ref], .move(to: destination, markingSeen: markingSeen && wasUnread),
            unread: wasUnread ? [ref] : [], flagged: envelope.flags.contains(.flagged) ? [ref] : [],
            by: .list(self, through: client)
        ).value
        guard outcome.failed.contains(ref) else { return }
        if mail.restore(ref, seen: outcome.markedRead.contains(ref) ? true : nil) { rebuild() }
        errorMessage = outcome.message
    }

    private func applyFlag(_ flag: Flag, added: Bool, to refs: Set<MessageRef>) {
        if mail.applyFlag(flag, added: added, to: refs) { rebuild() }
    }

    /// The messages `refs` names have left their folders: the ones listed
    /// here leave the list, and are named for a reader to close on.
    private func remove(_ refs: Set<MessageRef>) {
        let taken = mail.remove(refs)
        guard !taken.isEmpty else { return }
        removals = FlaggedRemovals(tick: removals.tick + 1, refs: taken)
        rebuild()
    }

    // MARK: - A feed item's row

    func setRead(_ item: RssItem, _ isRead: Bool) async {
        await mark(item, .read(isRead))
    }

    /// Read to unread and back, judged by what the store holds: the
    /// caller's copy can be the reader's, older than the last mark.
    func toggleRead(_ item: RssItem) async {
        let stored = await feedStore.stored(item) ?? item
        await setRead(item, !stored.isRead)
    }

    func toggleDefaultFlag(on item: RssItem) async {
        await toggleFlag(slot: defaultFlag.slot, on: item)
    }

    /// Sets the flag in palette slot `slot` on an item that lacks it and
    /// clears it on one that carries it, judged by what the store holds.
    func toggleFlag(slot: String, on item: RssItem) async {
        let stored = await feedStore.stored(item) ?? item
        await mark(item, .flag(slot: slot, isSet: !stored.carries(slot: slot)))
    }

    /// Opening an item marks it read when the feed reader's own preference
    /// says so.
    func didOpen(_ item: RssItem) async {
        guard preferences.rssMarkAsRead == .onOpen, !item.isRead else { return }
        await setRead(item, true)
    }

    /// A control's mark on a feed row: shown at once, then written and
    /// sent; afterwards the half is what the store holds, because the
    /// server can refuse a flag it no longer lists.
    private func mark(_ item: RssItem, _ mark: FeedItemMark) async {
        guard feedStore.engine != nil else { return }
        if feed.apply(mark, to: item) { rebuild() }
        _ = await feedStore.write(mark, to: item)
        await readFeed()
    }
}

// What the rest of the app did to this list's messages: a reader opened
// from it, another window's list, a compose session.
extension FlaggedListViewModel: MailEventSubscriber {
    func receive(_ event: MailEvent) {
        switch event.change {
        case .removed(let refs):
            remove(Set(refs))
        case .restored(let ref, let markUnread):
            if mail.restore(ref, seen: markUnread ? false : nil) { rebuild() }
        case .flagsChanged(let refs, let flag, let added):
            applyFlag(flag, added: added, to: Set(refs))
        case .draftReplaced, .readAdvance:
            // Drafts are not flagged mail's concern, and this list has no
            // selection to advance.
            break
        }
    }
}
