import Foundation
import Observation
import CabalmailKit

/// The mail state the folder list, message list, reader and composer share
/// for the signed-in account, in parts that each own a piece of it:
/// `counts`, the folder badges and the Inbox count behind the app badge;
/// `shields`, what keeps a list refresh from undoing a write made elsewhere;
/// and `events`, the changes the reader and composer post for every message
/// list. The parts know nothing of each other; what spans two of them (a
/// change that moves a count, a reply's shielded `\Answered`) is sent through
/// the store.
///
/// `AppState` owns one (`mailStore`) for its whole life and resets it in place
/// at sign-out (`forgetAccount()`), so a view model, or a reader callback that
/// outlives a session, never writes into a store nobody reads.
@Observable
@MainActor
public final class MailSessionStore {
    public let counts = MailCounts()
    let shields = MessageShields()
    let events = MailEvents()

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
    public func setInboxUnread(_ count: Int, fetchedThrough client: CabalmailClient) {
        guard acceptsCounts(from: client) else { return }
        counts.setInboxUnread(count)
    }

    /// The reader changed a flag on `ref` (or a reply marked it
    /// `\Answered`): post it for the lists, and for `\Seen` move the folder's
    /// unread count with it. `origin` is the reader's window.
    func postFlagChange(_ ref: MessageRef, flag: Flag, added: Bool, from origin: UUID?) {
        events.post(.flagsChanged([ref], flag: flag, added: added), from: origin)
        if flag == .seen {
            counts.applyUnreadDelta(folderPath: ref.folder, delta: added ? -1 : 1)
        }
    }

    /// The reader's dispose, move or purge of `ref` failed on the server, so
    /// the row its `.removed` dropped comes back (`.restored`). `markUnread`
    /// hands back the unread count the dispose's read mark took.
    func postRemovalFailed(_ ref: MessageRef, markUnread: Bool = false, from origin: UUID?) {
        events.post(.restored(ref, markUnread: markUnread), from: origin)
        if markUnread {
            counts.applyUnreadDelta(folderPath: ref.folder, delta: 1)
        }
    }

    /// Marks a replied-to message `\Answered` after its reply sends: post the
    /// change for the lists optimistically (so the replied arrow appears at
    /// once), then STORE the flag best-effort through `client`, the
    /// session's client when the reply sent (`AppState.client`; nil skips the
    /// STORE but not the event). Shielded via `setFlagWrite` so a refresh
    /// landing mid-write can't revert the row. No revert on failure — unlike
    /// the detail view's toggles there's no surface left to show an error on
    /// (the composer is gone), and the next full refresh restores truth. It
    /// comes from the composer, not from a main window's reader or list, so
    /// the change names no window.
    func markAnswered(_ ref: MessageRef, client: CabalmailClient?) {
        postFlagChange(ref, flag: .answered, added: true, from: nil)
        guard let client else { return }
        shields.setFlagWrite(ref, inFlight: true)
        Task {
            defer { shields.setFlagWrite(ref, inFlight: false) }
            try? await client.imapClient.setFlags(
                folder: ref.folder,
                uids: [ref.uid],
                flags: [.answered],
                operation: .add
            )
        }
    }

    /// Asks every mounted message list to hard-reload after a change made
    /// behind it (`onListRefreshRequested`).
    func requestListRefresh() {
        onListRefreshRequested()
    }

    /// Sign-out: what the store knows about the account goes, so the next
    /// account starts from none of it (#1825). The events have nothing to
    /// forget: each was delivered when it was posted, and none is kept.
    func forgetAccount() {
        counts.reset()
        shields.reset()
    }
}
