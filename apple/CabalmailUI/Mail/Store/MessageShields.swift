import Foundation
import CabalmailKit

/// The one record of the account's mail writes that are in flight, and of
/// the removals the server has just confirmed: what keeps a refresh from
/// undoing a write made anywhere, and what a folder's STATUS may still be
/// missing.
///
/// Every write to messages is bracketed here, by the mutation service
/// (`MailMutationService`) for every list, reader and reply, and by a list
/// for a moment longer while its own row is still leaving or being put
/// back. (A notification's actions write outside it, #1973, and the
/// whole-folder writes aren't bracketed.) Every reader asks it: a list's merge (`FolderWindowLoader.shieldFetched`)
/// keeps a row it is removing out and a row it is flagging at its local
/// flags, whichever list or reader started the write; and every writer of a
/// fetched STATUS (a list's refresh, the sidebar's, the unsubscribed-folder
/// banner's, the Inbox badge poller, the Check Inbox intent) bounds the
/// counts by the writes the STATUS may predate (`unreadBound`,
/// `flaggedBound`).
///
/// Part of `MailSessionStore` (`shields`). Read when a merge or a count
/// lands, never from a view body, so it isn't observed.
@MainActor
final class MessageShields {
    /// One flag write: which flag, and whether it is being added. A nil
    /// flag is a write whose caller doesn't name it (`setFlagWrite`): it
    /// shields the row and says nothing about counts.
    struct FlagWrite: Hashable, Sendable {
        let flag: Flag?
        let added: Bool
    }

    /// Removals in flight (dispose, move, purge), with how many writers
    /// hold each: a message is removed once at a time, but a reader's
    /// bracket and a list's can overlap on it.
    private var removals: [MessageRef: Int] = [:]

    /// Flag writes in flight per message, with how many writers hold each.
    private var flagWrites: [MessageRef: [FlagWrite: Int]] = [:]

    /// Messages the server has confirmed gone from their folders -- a
    /// dispose, move or purge landed -- with when that was confirmed. The
    /// in-flight entries end when a write resolves, but a refresh already in
    /// flight can still answer with the folder as it was and put the message
    /// back (the list then shifts under the user's pointer). IMAP never
    /// reuses a UID within a mailbox, so a fetch that still carries one of
    /// these is stale by definition, and the merge drops it. Entries age out
    /// after `confirmedRemovalWindow`, longer than any request can stay in
    /// flight.
    private(set) var confirmedRemovals: [MessageRef: ContinuousClock.Instant] = [:]

    /// Flag writes that ended, per folder, with when and which way: a
    /// STATUS asked before one ended may not count it yet (#1880).
    private var endedFlagWrites: [EndedFlagWrite] = []

    private struct EndedFlagWrite {
        let folder: String
        let write: FlagWrite
        let endedAt: ContinuousClock.Instant
    }

    /// Plain moves of unread messages into a folder that are in flight,
    /// with how many: the folder's unread count rose before the move landed,
    /// so a STATUS asked before then may not count them yet.
    private var arrivals: [String: Int] = [:]

    /// Those moves that ended, per folder, with when.
    private var endedArrivals: [(folder: String, endedAt: ContinuousClock.Instant)] = []

    /// How long a confirmed removal or an ended flag write keeps bounding a
    /// merge or a count. A request can't be in flight this long (the API
    /// gateway gives up after 29 s), so by then no fetch issued before the
    /// write can still land.
    static let confirmedRemovalWindow: Duration = .seconds(60)

    /// How long a request can stay out: the API gateway gives up after 29 s.
    /// A reply answered now was asked no longer ago than this.
    static let longestRequest: Duration = .seconds(30)

    init() {}

    // MARK: - Writers

    /// A removal of `refs` is going out.
    func beginRemoval(_ refs: some Sequence<MessageRef>) {
        for ref in refs { removals[ref, default: 0] += 1 }
    }

    /// A removal begun with `beginRemoval` resolved, either way.
    func endRemoval(_ refs: some Sequence<MessageRef>) {
        for ref in refs {
            guard let held = removals[ref] else { continue }
            removals[ref] = held > 1 ? held - 1 : nil
        }
    }

    /// `beginRemoval` (`true`) or `endRemoval` (`false`) for one message,
    /// as a flag. Safe to call `false` for a message that was never begun.
    func setMoveInFlight(_ ref: MessageRef, inFlight: Bool) {
        if inFlight { beginRemoval([ref]) } else { endRemoval([ref]) }
    }

    /// A STORE of `flag` (added, or removed) on `refs` is going out.
    func beginFlagWrite(_ refs: some Sequence<MessageRef>, flag: Flag, added: Bool) {
        let write = FlagWrite(flag: flag, added: added)
        for ref in refs { flagWrites[ref, default: [:]][write, default: 0] += 1 }
    }

    /// A STORE begun with `beginFlagWrite` resolved, either way. It is
    /// remembered per folder for the window, since a STATUS asked before it
    /// ended may not count it.
    func endFlagWrite(
        _ refs: some Sequence<MessageRef>,
        flag: Flag,
        added: Bool,
        at now: ContinuousClock.Instant = .now
    ) {
        let write = FlagWrite(flag: flag, added: added)
        var folders: Set<String> = []
        for ref in refs {
            guard var writes = flagWrites[ref], let held = writes[write] else { continue }
            writes[write] = held > 1 ? held - 1 : nil
            flagWrites[ref] = writes.isEmpty ? nil : writes
            folders.insert(ref.folder)
        }
        endedFlagWrites.removeAll { now - $0.endedAt >= Self.confirmedRemovalWindow }
        endedFlagWrites += folders.map { EndedFlagWrite(folder: $0, write: write, endedAt: now) }
    }

    /// A flag write whose flag the caller doesn't name: it shields the row's
    /// flags from a merge and says nothing about counts. Safe to call
    /// `false` for a message that was never inserted.
    func setFlagWrite(_ ref: MessageRef, inFlight: Bool) {
        let write = FlagWrite(flag: nil, added: true)
        if inFlight {
            flagWrites[ref, default: [:]][write, default: 0] += 1
        } else if var writes = flagWrites[ref], let held = writes[write] {
            writes[write] = held > 1 ? held - 1 : nil
            flagWrites[ref] = writes.isEmpty ? nil : writes
        }
    }

    /// Unread messages are being moved into `folder`, whose unread count
    /// has already risen for them.
    func beginArrival(into folder: String) {
        arrivals[folder, default: 0] += 1
    }

    /// A move begun with `beginArrival` resolved, either way. It is
    /// remembered for the window, since a STATUS asked before it ended may
    /// not count the messages yet.
    func endArrival(into folder: String, at now: ContinuousClock.Instant = .now) {
        guard let held = arrivals[folder] else { return }
        arrivals[folder] = held > 1 ? held - 1 : nil
        endedArrivals.removeAll { now - $0.endedAt >= Self.confirmedRemovalWindow }
        endedArrivals.append((folder, now))
    }

    /// Record that the server confirmed `refs` gone from their folders.
    /// Entries past the window are dropped for the folders recorded into,
    /// as they always were; other folders' entries are left for their own
    /// next record.
    func recordConfirmedRemovals(
        _ refs: some Sequence<MessageRef>,
        at now: ContinuousClock.Instant = .now
    ) {
        let refs = Array(refs)
        let folders = Set(refs.map(\.folder))
        confirmedRemovals = confirmedRemovals.filter {
            !folders.contains($0.key.folder) || now - $0.value < Self.confirmedRemovalWindow
        }
        for ref in refs { confirmedRemovals[ref] = now }
    }

    /// Forget a folder's confirmed removals: a changed UIDVALIDITY starts the
    /// UID space over, so the old numbers say nothing about the new ones.
    func clearConfirmedRemovals(folderPath: String) {
        confirmedRemovals = confirmedRemovals.filter { $0.key.folder != folderPath }
    }

    // MARK: - Readers

    /// Every message with a removal in flight, from any writer.
    var pendingMoveRefs: Set<MessageRef> { Set(removals.keys) }

    /// Every message with a flag write in flight, from any writer.
    var pendingFlagWriteRefs: Set<MessageRef> { Set(flagWrites.keys) }

    func isRemoving(_ ref: MessageRef) -> Bool { removals[ref] != nil }

    func isWritingFlags(_ ref: MessageRef) -> Bool { flagWrites[ref] != nil }

    /// True while a removal out of `folderPath` is in flight: a STATUS of
    /// that folder may still count the message.
    func hasRemovalInFlight(folderPath: String) -> Bool {
        removals.keys.contains { $0.folder == folderPath }
    }

    /// The messages confirmed gone from `folderPath` within the window.
    func confirmedRemovalRefs(folderPath: String, now: ContinuousClock.Instant = .now) -> Set<MessageRef> {
        Set(confirmedRemovals.compactMap { ref, confirmedAt in
            ref.folder == folderPath && now - confirmedAt < Self.confirmedRemovalWindow ? ref : nil
        })
    }

    /// True when a removal from `folderPath` was confirmed after `instant` --
    /// that is, while a request issued at `instant` may have been answered
    /// from the folder as it stood before the removal.
    func removalConfirmed(folderPath: String, after instant: ContinuousClock.Instant) -> Bool {
        confirmedRemovals.contains { $0.key.folder == folderPath && $0.value > instant }
    }

    /// Which way a STATUS of `folderPath` asked at `askedAt` may move the
    /// folder's unread count. A `\Seen` add in flight, or ended since, may
    /// not be counted in it yet, so the reply may still count that message
    /// unread: it may lower the count but not raise it. A `\Seen` removal is
    /// the mirror image, and so is an unread message moving in; a removal in
    /// flight or confirmed since lowers it like a read. Both at once hold
    /// the count where it is (#1880).
    func unreadBound(folderPath: String, askedAt: ContinuousClock.Instant) -> CountBound {
        let removing = hasRemovalInFlight(folderPath: folderPath)
            || removalConfirmed(folderPath: folderPath, after: askedAt)
        let arriving = arrivals[folderPath] != nil
            || endedArrivals.contains { $0.folder == folderPath && $0.endedAt > askedAt }
        return bound(
            lowering: removing || writes(.seen, added: true, in: folderPath, since: askedAt),
            raising: arriving || writes(.seen, added: false, in: folderPath, since: askedAt)
        )
    }

    /// The same for the folder's flagged count: a `\Flagged` add raises it,
    /// a removal of the flag or of a message lowers it.
    func flaggedBound(folderPath: String, askedAt: ContinuousClock.Instant) -> CountBound {
        let removing = hasRemovalInFlight(folderPath: folderPath)
            || removalConfirmed(folderPath: folderPath, after: askedAt)
        return bound(
            lowering: removing || writes(.flagged, added: false, in: folderPath, since: askedAt),
            raising: writes(.flagged, added: true, in: folderPath, since: askedAt)
        )
    }

    private func bound(lowering: Bool, raising: Bool) -> CountBound {
        switch (lowering, raising) {
        case (true, true): return .held
        case (true, false): return .lowerOnly
        case (false, true): return .raiseOnly
        case (false, false): return .free
        }
    }

    /// Whether a write of `flag` in `added`'s direction to a message in
    /// `folderPath` is in flight, or ended after `instant`.
    private func writes(
        _ flag: Flag,
        added: Bool,
        in folderPath: String,
        since instant: ContinuousClock.Instant
    ) -> Bool {
        let write = FlagWrite(flag: flag, added: added)
        return flagWrites.contains { $0.key.folder == folderPath && $0.value[write] != nil }
            || endedFlagWrites.contains { $0.folder == folderPath && $0.write == write && $0.endedAt > instant }
    }

    /// Sign-out's share of `MailSessionStore.forgetAccount()`: nothing the
    /// last account had in flight or confirmed shields the next account's
    /// lists or bounds its counts. A late write from its reader can still
    /// land here afterwards, as before the move.
    func reset() {
        confirmedRemovals = [:]
        removals = [:]
        flagWrites = [:]
        endedFlagWrites = []
        arrivals = [:]
        endedArrivals = []
    }
}

/// Which way a fetched count may move the count already shown, given the
/// writes the fetch may predate (`MessageShields.unreadBound`).
enum CountBound: Equatable, Sendable {
    /// Nothing in flight: the fetched count stands.
    case free
    /// A write that lowers the count may not be in the fetch yet.
    case lowerOnly
    /// A write that raises it may not be.
    case raiseOnly
    /// Both: keep the count shown.
    case held

    /// The count to show: `fetched`, kept from moving against the writes it
    /// may predate, from `current`, the count shown now.
    func bound(_ fetched: Int, from current: Int) -> Int {
        switch self {
        case .free: return fetched
        case .lowerOnly: return min(fetched, current)
        case .raiseOnly: return max(fetched, current)
        case .held: return current
        }
    }
}
