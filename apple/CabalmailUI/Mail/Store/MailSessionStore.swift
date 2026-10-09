import Foundation
import Observation
import CabalmailKit

/// The mail state the folder list, message list, reader and composer share
/// for the signed-in account, in parts that each own a piece of it:
/// `counts`, the folder badges and the Inbox count behind the app badge;
/// `shields`, the one record of writes in flight, which keeps a refresh from
/// undoing a write made anywhere and a STATUS from counting it twice;
/// `events`, the changes posted for every message list and reader;
/// `mutations`, the one place the app's writes go through (a notification's
/// actions aside, #1973), which uses the other three; and `folderPollers`,
/// the change watching of the folders open in message lists, one watcher and
/// tick per folder however many windows show it. The first three know
/// nothing of each other.
///
/// `AppState` owns one (`mailStore`) for its whole life and resets it in place
/// at sign-out (`forgetAccount()`), so a view model, or a write that answers
/// after its session, never writes into a store nobody reads.
@Observable
@MainActor
public final class MailSessionStore {
    public let counts = MailCounts()
    let shields = MessageShields()
    let events = MailEvents()
    /// The app's writes to mail go through here (`MailMutationService`).
    let mutations: MailMutationService
    /// The change watching of the folders open in message lists: one watcher
    /// and tick per folder, whose STATUS every list on it takes
    /// (`FolderPollers`).
    let folderPollers: FolderPollers

    /// The session lifecycle's record of which clients' sessions have ended
    /// (`AppState.teardownGate`, which marks a client ended before sign-out
    /// resets this store). `acceptsCounts(from:)` answers from it.
    @ObservationIgnored private let teardownGate: SessionTeardownGate

    /// Hard-reloads every mounted message list. `AppState` points this at its
    /// own refresh request once, when it creates the store, so a view model
    /// that changes a folder's contents behind the list (Mark All as Read,
    /// Empty Trash) asks for it without holding `AppState`, and no
    /// construction site can forget to wire it.
    @ObservationIgnored var onListRefreshRequested: @MainActor () -> Void = {}

    /// Built by `AppState` only, over its own `teardownGate`: a store over
    /// any other gate would never see that sign-out ended a client.
    init(teardownGate: SessionTeardownGate) {
        self.teardownGate = teardownGate
        folderPollers = FolderPollers(teardownGate: teardownGate)
        mutations = MailMutationService(counts: counts, shields: shields, events: events, teardownGate: teardownGate)
        mutations.onListRefreshRequested = { [weak self] in self?.requestListRefresh() }
    }

    /// Whether counts fetched through `client` still belong to the account
    /// on screen: false once its session has started ending. A STATUS that
    /// answers during or after a sign-out would otherwise write the last
    /// account's counts back after the reset, where the next account starts
    /// from them and saves their totals as its own (#1848). Every writer of a
    /// count it fetched checks this after the fetch, and so does every
    /// unread change that lands after a server call: a revert when the call
    /// fails, or a change applied once it answers (#1851).
    func acceptsCounts(from client: CabalmailClient) -> Bool {
        !teardownGate.hasEnded(client)
    }

    /// The Inbox unread count a caller outside this module fetched through
    /// `client` (the iOS Check Inbox intent), written to the app badge only
    /// if `acceptsCounts(from:)` still takes it. The intent used to write it
    /// straight to `counts`, so a STATUS that answered after a sign-out put
    /// the signed-out account's count back on the badge (#1892).
    ///
    /// It is bounded by the writes it may predate, as the badge poller's is.
    /// The intent doesn't say when it asked, so it is taken to have asked as
    /// long ago as a request can stay out (`MessageShields.longestRequest`).
    public func setInboxUnread(_ count: Int, fetchedThrough client: CabalmailClient) {
        guard acceptsCounts(from: client) else { return }
        counts.setInboxUnread(polledInboxUnread(count, askedAt: .now - MessageShields.longestRequest))
    }

    /// The badge's Inbox unread count for a STATUS asked at `askedAt`,
    /// bounded by the writes it may predate: a mark-read still going out
    /// then, or landed since, may be missing from it, and it may not put the
    /// badge back up (#1880). Only a count a STATUS set is a base to bound
    /// against: the first poll of a session takes its answer as it is, and
    /// makes the badge's count a counted one. The badge poller asks this
    /// (`SessionPollers.boundInboxUnread`).
    func polledInboxUnread(_ count: Int, askedAt: ContinuousClock.Instant) -> Int {
        defer { counts.inboxUnreadIsCounted = true }
        guard counts.inboxUnreadIsCounted else { return count }
        return shields.unreadBound(folderPath: "INBOX", askedAt: askedAt).bound(count, from: counts.inboxUnreadCount)
    }

    /// A folder's unread and total counts from a STATUS asked at `askedAt`,
    /// bounded by the writes that reply may predate: a `\Seen` change, or a
    /// removal, in flight then or since (`MessageShields.unreadBound`). Each
    /// is bounded against what the sidebar shows now, when that came from a
    /// STATUS this session, recently (`MailCounts.isCounted`); a guessed or seeded
    /// count, or none, takes the reply as it is. What every writer of a
    /// fetched STATUS sets the sidebar from (#1880).
    func boundedFolderCounts(
        unread: Int,
        total: Int,
        folderPath: String,
        askedAt: ContinuousClock.Instant
    ) -> (unread: Int, total: Int) {
        let unreadBound = shields.unreadBound(folderPath: folderPath, askedAt: askedAt)
        let removing = shields.hasRemovalInFlight(folderPath: folderPath)
            || shields.removalConfirmed(folderPath: folderPath, after: askedAt)
        let counted = counts.isCounted(folderPath, askedAt: askedAt)
        let shownUnread = counted ? counts.folderUnreadCounts[folderPath] : nil
        let shownTotal = counted ? counts.folderTotalCounts[folderPath] : nil
        return (
            shownUnread.map { unreadBound.bound(unread, from: $0) } ?? unread,
            removing ? shownTotal.map { min(total, $0) } ?? total : total
        )
    }

    /// A folder's flagged count from a STATUS asked at `askedAt`, bounded by
    /// the `\Flagged` writes and removals it may predate, against the count
    /// shown when a STATUS set it this session; otherwise the reply as it is.
    func boundedFlaggedCount(_ flagged: Int, folderPath: String, askedAt: ContinuousClock.Instant) -> Int {
        guard counts.isFlaggedCounted(folderPath, askedAt: askedAt),
              let shown = counts.folderFlaggedCounts[folderPath] else { return flagged }
        return shields.flaggedBound(folderPath: folderPath, askedAt: askedAt).bound(flagged, from: shown)
    }

    /// A message list's STATUS of its folder, asked at `askedAt`, fetched
    /// through `client`: the rule by which it reaches the folder's counts,
    /// which the list's Unread and Flagged pills and the sidebar both show.
    /// A reply that carried the unread and total counts sets them, bounded
    /// by the writes it may predate (`boundedFolderCounts`); one that carried
    /// the flagged count sets it, bounded the same way. A reply from a session
    /// that has started ending writes nothing (#1848).
    func takeStatus(
        _ status: FolderStatus,
        folderPath: String,
        askedAt: ContinuousClock.Instant,
        fetchedThrough client: CabalmailClient
    ) {
        guard acceptsCounts(from: client), !folderPath.isEmpty else { return }
        if let unread = status.unseen, let total = status.messages {
            let bounded = boundedFolderCounts(unread: unread, total: total, folderPath: folderPath, askedAt: askedAt)
            counts.setFolderCounts(folderPath: folderPath, unread: bounded.unread, total: bounded.total)
        }
        if let flagged = status.flagged {
            counts.setFlaggedCount(
                folderPath: folderPath,
                count: boundedFlaggedCount(flagged, folderPath: folderPath, askedAt: askedAt)
            )
        }
    }

    /// The same for a reply that may predate a removal the list has already
    /// applied: it would count the departed message again, so it may only
    /// lower the counts shown, bounded as `takeStatus` bounds them, sets no
    /// total, and saves what is shown, with `shownTotal`, the list's own
    /// total, for the next offline launch. What it shows is a base for the
    /// next reply's bounds, as a count it set would be.
    func takeStatus(
        _ status: FolderStatus,
        predatingRemovalIn folderPath: String,
        askedAt: ContinuousClock.Instant,
        shownTotal: Int,
        fetchedThrough client: CabalmailClient
    ) {
        guard acceptsCounts(from: client), !folderPath.isEmpty else { return }
        if let fetched = status.unseen, let shown = counts.folderUnreadCounts[folderPath] {
            var unread = min(fetched, shown)
            if counts.isCounted(folderPath, askedAt: askedAt) {
                unread = shields.unreadBound(folderPath: folderPath, askedAt: askedAt).bound(unread, from: shown)
            }
            counts.show(unread: unread, folderPath: folderPath, counted: true)
            // `client.folderStatus` saved the reply as it came, but it may
            // count a message already removed here: save what is shown.
            counts.savedFolderCounts.countChanged(folderPath, unread: unread, total: shownTotal)
        }
        if let fetched = status.flagged, let shown = counts.folderFlaggedCounts[folderPath] {
            var flagged = min(fetched, shown)
            if counts.isFlaggedCounted(folderPath, askedAt: askedAt) {
                flagged = shields.flaggedBound(folderPath: folderPath, askedAt: askedAt).bound(flagged, from: shown)
            }
            counts.show(flagged: flagged, folderPath: folderPath, counted: true)
        }
    }

    /// Marks a replied-to message `\Answered` after its reply sends, or once
    /// the outbox owns it, through the mutation service with `client`, the
    /// session's client when the reply sent (`AppState.client`): every list
    /// shows the replied arrow at once. Nothing is taken back if the STORE
    /// fails (`changing: []`): a reply queued offline still goes, the message
    /// may be `\Answered` already, and there's no surface left to show an
    /// error on, so the next full refresh restores truth. A nil client (no
    /// session) still shows the arrow, and makes no STORE. It comes from the
    /// composer, not from a main window's reader or list, so the change names
    /// no window.
    func markAnswered(_ ref: MessageRef, client: CabalmailClient?) {
        guard let client else {
            events.post(.flagsChanged([ref], flag: .answered, added: true), from: nil)
            return
        }
        mutations.setFlag(.answered, added: true, on: [ref], changing: [], by: .composer(through: client))
    }

    /// Asks every mounted message list to hard-reload after a change made
    /// behind it (`onListRefreshRequested`).
    func requestListRefresh() {
        onListRefreshRequested()
    }

    /// Sign-out: what the store knows about the account goes, so the next
    /// account starts from none of it (#1825), and every folder's poller
    /// stops, so no STATUS of the ended session goes out or lands, and its
    /// client is let go. The events have nothing to forget: each was
    /// delivered when it was posted, and none is kept.
    func forgetAccount() {
        counts.reset()
        shields.reset()
        folderPollers.stopAll()
    }
}
