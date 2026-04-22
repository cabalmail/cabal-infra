import Foundation
import Observation
import CabalmailKit

/// Backs `MessageListView`. Owns the sliding UID window, envelope cache
/// hydration, search results, and the per-row mark-as-read / dispose actions.
///
/// Window strategy (per Phase 4 plan): on open, `STATUS` the folder to pick
/// up `UIDNEXT`, then `UID FETCH (uidNext - pageSize):uidNext`. Older pages
/// lazy-load as the user scrolls. The envelope cache stores everything keyed
/// by `UIDVALIDITY` so reopen is instant while the refresh runs in the
/// background.
@Observable
@MainActor
final class MessageListViewModel {
    let folder: Folder
    private let client: CabalmailClient
    private let preferences: Preferences
    private let pageSize: UInt32 = 50

    var envelopes: [Envelope] = []
    var isLoading = false
    var isLoadingMore = false
    var errorMessage: String?
    var searchQuery: String = ""

    private var uidValidity: UInt32?
    private var lowestUID: UInt32?
    private var hasMore = true

    /// Foreground-only IDLE loop. Nil when the view is offscreen; started on
    /// `task`, stopped on `onDisappear`. Separated from the refresh path so
    /// UIDVALIDITY changes, pagination, and flag toggles never fight the
    /// watcher for the main actor.
    private var watcher: MailboxWatcher?
    private var watcherTask: Task<Void, Never>?
    /// Coalescing timestamp — if `.changed` fires in bursts (e.g. server
    /// delivers three messages in quick succession) we collapse them into
    /// one refresh by gating on elapsed time.
    private var lastRefreshFromWatcher: Date = .distantPast

    /// UIDs currently in flight through `dispose(_:)`. Every swipe enqueues
    /// the UID here, removes it in `defer`, and short-circuits duplicate
    /// taps. Prevents re-entrant SwiftUI list mutation when a user taps
    /// archive rapidly on several rows — the previous pattern queued one
    /// `UID MOVE` per tap and mutated `envelopes` on completion, which
    /// allowed `ForEach(model.envelopes)` to diff a shrinking array while
    /// the in-flight moves were still returning.
    private var pendingDisposeUIDs: Set<UInt32> = []

    init(folder: Folder, client: CabalmailClient, preferences: Preferences) {
        self.folder = folder
        self.client = client
        self.preferences = preferences
    }

    func loadInitial() async {
        guard envelopes.isEmpty else { return }
        await hydrateFromCache()
        await refresh()
    }

    /// Start the IDLE-backed auto-refresh loop. Called from the view's
    /// `.task` after `loadInitial()` settles. The watcher runs on its own
    /// actor and emits `.changed` whenever the server pushes an
    /// EXISTS/EXPUNGE/FETCH; we collapse bursts to a single refresh by
    /// gating on elapsed time (IMAP doesn't promise deduped notifications
    /// and a 10-message import can fire EXISTS ten times in a second).
    func startWatching() async {
        guard watcher == nil else { return }
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

    /// Tear down the watcher. View hooks this into `.onDisappear` so IDLE
    /// stops when the list isn't on-screen — we don't want to hold a
    /// background IMAP connection open for a mailbox the user isn't looking
    /// at (each session costs ~1 IMAP connection against Dovecot's pool).
    func stopWatching() async {
        watcherTask?.cancel()
        watcherTask = nil
        await watcher?.stop()
        watcher = nil
    }

    private func handleWatcherChanged() async {
        // Coalesce bursts — a multi-message delivery can push ten EXISTS
        // notifications inside a single second. One refresh is enough.
        let now = Date()
        guard now.timeIntervalSince(lastRefreshFromWatcher) > 1 else { return }
        lastRefreshFromWatcher = now
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let status = try await client.imapClient.status(path: folder.path)
            let uidNext = status.uidNext ?? 1
            let uidValidity = status.uidValidity ?? 0
            if self.uidValidity != uidValidity {
                try? await client.envelopeCache.invalidate(folder: folder.path)
                try? await client.bodyCache.invalidate(folder: folder.path)
                envelopes = []
                lowestUID = nil
            }
            self.uidValidity = uidValidity
            // Top page uses sequence-number FETCH via `topEnvelopes` — see
            // the protocol doc for why UID range fetches go wrong on sparse
            // folders. `loadMoreIfNeeded` handles older pages by UID.
            let messages = UInt32(max(0, status.messages ?? 0))
            let fetched = try await client.imapClient.topEnvelopes(
                folder: folder.path,
                limit: pageSize,
                totalMessages: messages
            )
            try await applyRefreshPage(fetched, uidNext: uidNext, uidValidity: uidValidity)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: Envelope) async {
        guard hasMore, !isLoadingMore, !isLoading,
              pendingDisposeUIDs.isEmpty,
              envelopes.last?.uid == currentItem.uid,
              let lowestUID,
              lowestUID > 1 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let upper = lowestUID - 1
            let lower = upper > pageSize ? upper - pageSize : 1
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                range: lower...upper
            )
            mergeFetched(fetched)
            // An empty fetch on a range above UID 1 means the server has no
            // messages in that band — don't spin indefinitely decrementing
            // `lowestUID` one at a time. Flag "no more" explicitly.
            if fetched.isEmpty {
                hasMore = false
                self.lowestUID = lower
            } else {
                let newLowest = fetched.map(\.uid).min() ?? upper
                self.lowestUID = newLowest
                hasMore = newLowest > 1
            }
            if let uidValidity, let uidNext = envelopes.map(\.uid).max() {
                try await persistCache(uidValidity: uidValidity, uidNext: uidNext + 1)
            }
        } catch {
            // Best-effort pagination — don't surface an error unless we're
            // blocked entirely.
        }
    }

    func runSearch() async {
        guard !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty else {
            await refresh()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.imapClient.connectAndAuthenticate()
            let query = "TEXT \"\(searchQuery.replacingOccurrences(of: "\"", with: "\\\""))\""
            let matches = try await client.imapClient.search(folder: folder.path, query: query)
            guard !matches.isEmpty else {
                envelopes = []
                return
            }
            let sorted = matches.sorted()
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                range: (sorted.first ?? 1)...(sorted.last ?? 1)
            )
            envelopes = fetched
                .filter { matches.contains($0.uid) }
                .sorted { $0.uid > $1.uid }
        } catch {
            errorMessage = "\(error)"
        }
    }

    func markRead(_ envelope: Envelope) async {
        await setFlag(.seen, add: true, envelope: envelope)
    }

    /// Flip the `\Seen` flag — drives the leading (left-to-right) swipe
    /// action. Mirrors the Mail.app convention that the same gesture
    /// toggles between read and unread rather than having two.
    func toggleSeen(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.seen)
        await setFlag(.seen, add: add, envelope: envelope)
    }

    func toggleFlag(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.flagged)
        await setFlag(.flagged, add: add, envelope: envelope)
    }

    /// Dispose target is the current `Preferences.disposeAction` — Archive
    /// or Trash. The preference is read on every invocation so a user who
    /// toggles the setting mid-session sees the swipe behavior change
    /// immediately.
    ///
    /// Also matches the React webmail behavior by marking the message
    /// `\Seen` before the move: archived == read. The seen flag is set
    /// while the message is still in the current folder; post-move the UID
    /// no longer exists here so `STORE` would reject it.
    ///
    /// After the server `UID MOVE` succeeds, the UID is pruned from both
    /// the in-memory envelope list *and* the persistent envelope cache,
    /// and the message body cache entry is dropped. Without the cache
    /// prune, relaunching the app re-hydrated the Inbox from a snapshot
    /// that still contained the archived UIDs — the "archived messages
    /// reappear after relaunch" bug.
    func dispose(_ envelope: Envelope) async {
        guard pendingDisposeUIDs.insert(envelope.uid).inserted else { return }
        defer { pendingDisposeUIDs.remove(envelope.uid) }

        let destination = preferences.disposeAction.destinationFolder
        do {
            if !envelope.flags.contains(.seen) {
                try await client.imapClient.setFlags(
                    folder: folder.path,
                    uids: [envelope.uid],
                    flags: [.seen],
                    operation: .add
                )
            }
            try await client.imapClient.move(
                folder: folder.path,
                uids: [envelope.uid],
                destination: destination
            )
            envelopes.removeAll { $0.uid == envelope.uid }
            if let uidValidity {
                try? await client.envelopeCache.remove(
                    uids: [envelope.uid],
                    folder: folder.path
                )
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: envelope.uid
                )
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The currently-configured dispose action, exposed so the view can
    /// render the right swipe-action label and icon without reaching into
    /// the preferences environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

    /// Drop a UID from the in-memory envelope list after it was disposed
    /// elsewhere (currently: the detail-view archive button). The detail
    /// view model already pruned the envelope + body caches; this only
    /// touches the list's in-memory copy so the row disappears immediately
    /// without a server round trip.
    func pruneEnvelope(uid: UInt32) {
        envelopes.removeAll { $0.uid == uid }
    }
}

// MARK: - Internals

// Lifted into an extension so the primary type body stays under SwiftLint's
// 250-line cap. Same-file extension — all helpers remain file-private to
// the view model.
extension MessageListViewModel {
    func setFlag(_ flag: Flag, add: Bool, envelope: Envelope) async {
        do {
            try await client.imapClient.setFlags(
                folder: folder.path,
                uids: [envelope.uid],
                flags: [flag],
                operation: add ? .add : .remove
            )
            if let index = envelopes.firstIndex(where: { $0.uid == envelope.uid }) {
                var updated = envelopes[index]
                var flags = updated.flags
                if add { flags.insert(flag) } else { flags.remove(flag) }
                updated = Envelope(
                    uid: updated.uid,
                    messageId: updated.messageId,
                    date: updated.date,
                    subject: updated.subject,
                    from: updated.from,
                    sender: updated.sender,
                    replyTo: updated.replyTo,
                    to: updated.to,
                    cc: updated.cc,
                    bcc: updated.bcc,
                    inReplyTo: updated.inReplyTo,
                    flags: flags,
                    internalDate: updated.internalDate,
                    size: updated.size,
                    hasAttachments: updated.hasAttachments
                )
                envelopes[index] = updated
            }
        } catch {
            errorMessage = "\(error)"
        }
    }

    private func hydrateFromCache() async {
        if let snapshot = await client.envelopeCache.snapshot(for: folder.path) {
            uidValidity = snapshot.uidValidity
            envelopes = snapshot.envelopes.values
                .sorted { $0.uid > $1.uid }
            lowestUID = envelopes.map(\.uid).min()
        }
    }

    private func mergeFetched(_ fetched: [Envelope]) {
        var byUID: [UInt32: Envelope] = Dictionary(
            uniqueKeysWithValues: envelopes.map { ($0.uid, $0) }
        )
        for envelope in fetched {
            byUID[envelope.uid] = envelope
        }
        envelopes = byUID.values.sorted { $0.uid > $1.uid }
    }

    private func persistCache(uidValidity: UInt32, uidNext: UInt32) async throws {
        try await client.envelopeCache.merge(
            envelopes: envelopes,
            uidValidity: uidValidity,
            uidNext: uidNext,
            into: folder.path
        )
    }

    /// Merges a top-page fetch into in-memory state and the envelope cache.
    /// `keepingRange` covers `min(fetched.uid)...uidNext`: any in-memory
    /// envelope in that band but missing from the fetch was moved or
    /// expunged elsewhere. An empty fetch means the folder is empty, so we
    /// replace the full cache.
    func applyRefreshPage(
        _ fetched: [Envelope],
        uidNext: UInt32,
        uidValidity: UInt32
    ) async throws {
        let fetchedUIDs = Set(fetched.map(\.uid))
        let keepingRange: ClosedRange<UInt32>? = fetched
            .map(\.uid).min()
            .map { lower in lower...max(uidNext, lower) }
        let disappeared: [UInt32] = keepingRange.map { range in
            envelopes.map(\.uid).filter { range.contains($0) && !fetchedUIDs.contains($0) }
        } ?? envelopes.map(\.uid)
        if !disappeared.isEmpty {
            envelopes.removeAll { disappeared.contains($0.uid) }
            for uid in disappeared {
                await client.bodyCache.remove(
                    folder: folder.path,
                    uidValidity: uidValidity,
                    uid: uid
                )
            }
        }
        mergeFetched(fetched)
        lowestUID = envelopes.map(\.uid).min() ?? lowestUID
        hasMore = (lowestUID ?? 0) > 1
        try await client.envelopeCache.replace(
            envelopes: fetched,
            uidValidity: uidValidity,
            uidNext: uidNext,
            keepingRange: keepingRange,
            into: folder.path
        )
    }
}
