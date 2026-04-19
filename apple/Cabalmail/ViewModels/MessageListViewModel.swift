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
            let startUID = uidNext > pageSize ? uidNext - pageSize : 1
            let fetched = try await client.imapClient.envelopes(
                folder: folder.path,
                range: startUID...max(uidNext, startUID)
            )
            mergeFetched(fetched)
            lowestUID = fetched.map(\.uid).min() ?? lowestUID
            hasMore = (lowestUID ?? 0) > 1
            try await persistCache(uidValidity: uidValidity, uidNext: uidNext)
            errorMessage = nil
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreIfNeeded(currentItem: Envelope) async {
        guard hasMore, !isLoadingMore,
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
            let newLowest = fetched.map(\.uid).min() ?? upper
            self.lowestUID = newLowest
            hasMore = newLowest > 1
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

    func toggleFlag(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.flagged)
        await setFlag(.flagged, add: add, envelope: envelope)
    }

    /// Dispose target is the current `Preferences.disposeAction` — Archive
    /// or Trash. The preference is read on every invocation so a user who
    /// toggles the setting mid-session sees the swipe behavior change
    /// immediately.
    func dispose(_ envelope: Envelope) async {
        let destination = preferences.disposeAction.destinationFolder
        do {
            try await client.imapClient.move(
                folder: folder.path,
                uids: [envelope.uid],
                destination: destination
            )
            envelopes.removeAll { $0.uid == envelope.uid }
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// The currently-configured dispose action, exposed so the view can
    /// render the right swipe-action label and icon without reaching into
    /// the preferences environment itself.
    var disposeAction: DisposeAction { preferences.disposeAction }

    // MARK: - Internals

    private func setFlag(_ flag: Flag, add: Bool, envelope: Envelope) async {
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
}
