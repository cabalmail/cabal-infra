import Foundation
import CabalmailKit

/// A list that takes its folder's STATUS from the folder's poller
/// (`FolderPollers`): a message list's view model, or a test's recorder.
/// Held weakly. For each poll a list is in, the poller calls
/// `beginFolderPoll()` before it asks the STATUS; hands the answer to
/// `refresh(prefetched:startingOver:)`, or the failure to
/// `folderPollFailed(_:ticket:)`; and gives the ticket back exactly once
/// (`releaseFolderPoll(_:)`): after the hand-off returns, or at once if the
/// list leaves or the poller stops while the STATUS is out.
@MainActor
protocol FolderPollSubscriber: AnyObject, Sendable {
    /// A STATUS of the list's folder is about to be asked for on its behalf:
    /// numbers the refresh ask it is to answer, so that it answers none asked
    /// for after it went out (`RefreshFlight`), and holds whatever shows the
    /// list as loading until the ticket comes back. Nil sits the poll out.
    func beginFolderPoll() -> FolderPollTicket?
    /// The poll's STATUS, carrying the list's own ask; never `startingOver`.
    func refresh(prefetched: PrefetchedStatus?, startingOver: Bool) async
    /// The poll's STATUS failed while the poller and the list's place on it
    /// were still there.
    func folderPollFailed(_ error: Error, ticket: FolderPollTicket) async
    /// The poll is over for the list: lets go of what the ticket holds.
    func releaseFolderPoll(_ ticket: FolderPollTicket)
}

/// A list's stake in one poll's STATUS (`FolderPollSubscriber`).
struct FolderPollTicket: Equatable {
    /// The refresh ask numbered for it in the list's own `RefreshFlight`.
    let ask: Int
    /// Whether it holds the list's loading.
    let holdsLoading: Bool
}

/// How the folder pollers keep time: the tick, the burst coalesce, and the
/// clock both read. A test swaps the clock for one it steps
/// (`FolderPollers.timing`). It never dates a STATUS: a poll's `askedAt` is
/// always the continuous clock's, which the mail store's write bounds
/// compare against.
struct FolderPollTiming {
    /// Between ticks. The first comes one interval after the poller starts:
    /// the list that made it has just loaded.
    var tickInterval: Duration = .seconds(60)
    /// A change this soon after the last one that polled joins that poll:
    /// one status poll can report an arrival and a removal both.
    var coalesceInterval: Duration = .seconds(1)
    var now: @MainActor () -> ContinuousClock.Instant = { .now }
    var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
}

/// The change watching of the folders open in message lists: one
/// `FolderPoller` per folder, made by the first list to subscribe and
/// stopped with the last, so a folder open in two windows is watched, and
/// asked for its STATUS, once rather than once per window.
///
/// Lists are held weakly and counted once each: subscribing again changes
/// nothing, leaving takes off only a list that is on, and a list that goes
/// away without leaving stops counting. A poller polls through the client
/// it was made over and is keyed by it as well as the path, so a list of a
/// session being replaced never shares the next session's poller, and a
/// client whose session has ended gets none. `MailSessionStore` owns one
/// (`folderPollers`); sign-out stops every poller (`stopAll()`).
@MainActor
final class FolderPollers {
    /// What each poller is made with. A test sets it before the first list
    /// subscribes; `AppState` builds the store, so it is no init argument.
    var timing = FolderPollTiming()

    private struct Key: Hashable {
        let path: String
        let client: ObjectIdentifier
    }

    private let teardownGate: SessionTeardownGate
    private var pollers: [Key: FolderPoller] = [:]

    init(teardownGate: SessionTeardownGate) {
        self.teardownGate = teardownGate
    }

    /// Puts `list` on the poller of `path` through `client`, making and
    /// starting it if `list` is the first. Synchronous, so a call that
    /// overlaps this one, or comes during the last list's stop, finds the map
    /// as this one left it.
    func subscribe(_ list: any FolderPollSubscriber, to path: String, through client: CabalmailClient) {
        guard !teardownGate.hasEnded(client) else { return }
        let key = Key(path: path, client: ObjectIdentifier(client))
        if let poller = pollers[key] {
            poller.add(list)
            return
        }
        let poller = FolderPoller(path: path, client: client, timing: timing)
        poller.onAbandoned = { [weak self] abandoned in self?.drop(abandoned) }
        pollers[key] = poller
        poller.add(list)
        poller.start()
    }

    /// Takes `list` off the poller of `path`. The last list off takes the
    /// poller out of the map and stops it before anything suspends, so a
    /// list back on screen meanwhile makes a fresh one (#1816), and returns
    /// it for the caller to wait on its watcher (`awaitWatcherStop()`). A
    /// list not on the poller changes nothing.
    @discardableResult
    func unsubscribe(
        _ list: any FolderPollSubscriber, from path: String, through client: CabalmailClient
    ) -> FolderPoller? {
        let key = Key(path: path, client: ObjectIdentifier(client))
        guard let poller = pollers[key], poller.remove(list), poller.isEmpty else { return nil }
        pollers[key] = nil
        poller.cancel()
        return poller
    }

    /// Sign-out (`MailSessionStore.forgetAccount()`): every poller stops at
    /// once, every ticket for a STATUS still out comes back, and no answer
    /// reaches a list (#1886). The lists' later `stopWatching()` finds
    /// nothing to leave.
    func stopAll() {
        let stopping = pollers.values
        pollers = [:]
        for poller in stopping { poller.cancel() }
    }

    /// The poller of `path` through `client`, while one runs; for tests.
    func poller(for path: String, through client: CabalmailClient) -> FolderPoller? {
        pollers[Key(path: path, client: ObjectIdentifier(client))]
    }

    /// A poller whose lists all went away without leaving: out of the map,
    /// unless a fresh one has taken its place, and stopped.
    private func drop(_ poller: FolderPoller) {
        let key = Key(path: poller.path, client: ObjectIdentifier(poller.client))
        if pollers[key] === poller { pollers[key] = nil }
        poller.cancel()
    }
}
