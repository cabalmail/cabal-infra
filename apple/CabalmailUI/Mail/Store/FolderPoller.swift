import Foundation
import CabalmailKit

/// One folder's poller (`FolderPollers`): the lists showing the folder, a
/// `MailboxWatcher` over its change stream (`ImapClient.idle(folder:)`, a
/// status poll every 30 s in production) and a tick. Each change the stream
/// reports -- unless it comes within a second of the last change that
/// polled, which covers it -- and each tick asks one flagged STATUS of the
/// folder for every list on it.
///
/// The stream reports only `UIDNEXT` advancing or the count dropping, so it
/// misses read and flag changes made elsewhere, and it goes quiet while it
/// backs off from a failing API; the tick is the full refresh that catches
/// those (it used to be each list view's own 60-second loop).
///
/// A poll numbers each list's refresh ask and holds its loading before the
/// STATUS goes out, as the list's own refresh would, then hands the answer
/// or the failure to each list still on the poller, in a task of that
/// list's own, which its leaving cancels. A list that joined after the
/// STATUS went out has just loaded, and waits for the next poll. One poll
/// runs at a time, hand-offs included; changes and ticks meanwhile make one
/// more poll after it.
@MainActor
final class FolderPoller {
    /// A list on the poller, held weakly, with its ticket for a STATUS still
    /// out and the refresh last handed to it.
    private final class Subscription {
        weak var list: (any FolderPollSubscriber)?
        var ticket: FolderPollTicket?
        var handOff: Task<Void, Never>?

        init(_ list: any FolderPollSubscriber) {
            self.list = list
        }
    }

    let path: String
    let client: CabalmailClient
    /// Told when a poll finds every list gone without leaving.
    var onAbandoned: @MainActor (FolderPoller) -> Void = { _ in }
    /// Change events heard, polls asked for (a change the coalesce let
    /// through, or a tick) and polls finished, hand-offs included: readable
    /// so a test can tell a dropped change from one on its way, and wait a
    /// poll out.
    private(set) var changesHeard = 0
    private(set) var pollsRequested = 0
    private(set) var pollsFinished = 0

    private let timing: FolderPollTiming
    private let watcher: MailboxWatcher
    private var subscriptions: [Subscription] = []
    private var tasks: [Task<Void, Never>] = []
    private let polls: AsyncStream<Void>
    private let askForPoll: AsyncStream<Void>.Continuation
    /// When the last change that polled arrived, for the coalesce.
    private var lastPolledChange: ContinuousClock.Instant?

    init(path: String, client: CabalmailClient, timing: FolderPollTiming) {
        self.path = path
        self.client = client
        self.timing = timing
        watcher = MailboxWatcher(folder: path, streamFactory: { folder in
            try await client.imapClient.idle(folder: folder)
        })
        // One request waits at most: however many arrive during a poll, one
        // more poll after it answers them all.
        let (polls, askForPoll) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.polls = polls
        self.askForPoll = askForPoll
    }

    /// No list is on the poller.
    var isEmpty: Bool { !subscriptions.contains { $0.list != nil } }

    /// The lists on the poller, each counted once.
    var subscriberCount: Int { subscriptions.filter { $0.list != nil }.count }

    /// Puts `list` on the poller; a list already on it stays as it is.
    func add(_ list: any FolderPollSubscriber) {
        subscriptions.removeAll { $0.list == nil }
        guard !subscriptions.contains(where: { $0.list === list }) else { return }
        subscriptions.append(Subscription(list))
    }

    /// Takes `list` off, false if it wasn't on: its ticket for a STATUS still
    /// out comes back now, and the refresh handed to it is cancelled.
    func remove(_ list: any FolderPollSubscriber) -> Bool {
        guard let index = subscriptions.firstIndex(where: { $0.list === list }) else { return false }
        release(subscriptions.remove(at: index))
        return true
    }

    /// Starts the watcher, the tick and the poll loop.
    func start() {
        tasks = [watchChanges(), tick(), runPolls()]
    }

    /// Stops the poller where it stands, synchronously: its tasks and the
    /// refreshes handed out are cancelled, every ticket for a STATUS still
    /// out comes back, the lists are let go and the watcher is told to stop.
    /// A STATUS that answers afterwards reaches no list (#1886).
    func cancel() {
        for task in tasks { task.cancel() }
        tasks = []
        askForPoll.finish()
        let leaving = subscriptions
        subscriptions = []
        // A loop, not `forEach(release)`: a main-actor method passed as a
        // plain function value loses its isolation under strict checking.
        for subscription in leaving { release(subscription) }
        let watcher = watcher
        Task { await watcher.stop() }
    }

    /// Returns once the watcher `cancel()` told to stop has stopped.
    func awaitWatcherStop() async {
        await watcher.stop()
    }

    // MARK: - Wakeups

    /// The watcher's change events. Opened from the task, so a poller
    /// stopped before it runs opens no stream; one stopped while the stream
    /// opens ends it, as the cancelled loop drops the stream, whose
    /// termination stops the watcher.
    private func watchChanges() -> Task<Void, Never> {
        let watcher = watcher
        return Task { [weak self] in
            guard !Task.isCancelled else { return }
            let events = await watcher.start()
            for await event in events where event == .changed {
                guard !Task.isCancelled, let self else { break }
                self.noteChange()
            }
        }
    }

    /// Sleeps first: the list that made the poller has just loaded.
    private func tick() -> Task<Void, Never> {
        let sleep = timing.sleep
        let interval = timing.tickInterval
        return Task { [weak self] in
            while !Task.isCancelled {
                await sleep(interval)
                guard !Task.isCancelled, let self else { return }
                self.requestPoll()
            }
        }
    }

    private func runPolls() -> Task<Void, Never> {
        let polls = polls
        return Task { [weak self] in
            for await _ in polls {
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    /// A change polls unless one that polled came within the coalesce.
    private func noteChange() {
        changesHeard += 1
        let now = timing.now()
        if let last = lastPolledChange, now - last <= timing.coalesceInterval { return }
        lastPolledChange = now
        requestPoll()
    }

    private func requestPoll() {
        pollsRequested += 1
        askForPoll.yield()
    }

    // MARK: - A poll

    /// One STATUS for every list on the poller now, each list's ask numbered
    /// and its loading held before it goes out, as `probeBeforeReset`
    /// numbers its own; then the answer, or the failure, goes to each of them
    /// still on the poller.
    private func poll() async {
        defer { pollsFinished += 1 }
        subscriptions.removeAll { $0.list == nil }
        guard !subscriptions.isEmpty else { return onAbandoned(self) }
        let asked = subscriptions
        for subscription in asked { subscription.ticket = subscription.list?.beginFolderPoll() }
        guard asked.contains(where: { $0.ticket != nil }) else { return }
        let askedAt = ContinuousClock.now
        let result: Result<FolderStatus, Error>
        do {
            result = .success(try await client.folderStatus(path: path, flagged: true))
        } catch {
            result = .failure(error)
        }
        // Stopped while the STATUS was out (the last list left, or sign-out):
        // stopping gave every ticket back, and the answer goes nowhere (#1886).
        guard !Task.isCancelled else { return }
        var handOffs: [Task<Void, Never>] = []
        for subscription in asked {
            // A list that left meanwhile has had its ticket back.
            guard let ticket = subscription.ticket, let list = subscription.list else { continue }
            subscription.ticket = nil
            let task = handOff(result, askedAt: askedAt, ticket: ticket, to: list)
            subscription.handOff = task
            handOffs.append(task)
        }
        for task in handOffs { await task.value }
    }

    /// One list's share of a poll, in a task of its own, so the list leaving
    /// cancels it alone; the task now owns the ticket and gives it back as it
    /// ends. A poll never supersedes a pass (`startingOver: false`), and a
    /// failure reaches the list only while its task runs.
    private func handOff(
        _ result: Result<FolderStatus, Error>,
        askedAt: ContinuousClock.Instant,
        ticket: FolderPollTicket,
        to list: any FolderPollSubscriber
    ) -> Task<Void, Never> {
        Task {
            defer { list.releaseFolderPoll(ticket) }
            switch result {
            case .success(let status):
                let prefetched = PrefetchedStatus(status: status, askedAt: askedAt, ask: ticket.ask)
                await list.refresh(prefetched: prefetched, startingOver: false)
            case .failure(let error):
                guard !Task.isCancelled else { return }
                await list.folderPollFailed(error, ticket: ticket)
            }
        }
    }

    /// Cancels the refresh handed to `subscription`'s list, and gives back
    /// its ticket for a STATUS still out.
    private func release(_ subscription: Subscription) {
        subscription.handOff?.cancel()
        subscription.handOff = nil
        guard let ticket = subscription.ticket else { return }
        subscription.ticket = nil
        subscription.list?.releaseFolderPoll(ticket)
    }
}
