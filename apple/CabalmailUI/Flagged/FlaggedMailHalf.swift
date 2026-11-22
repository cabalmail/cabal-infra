import Foundation
import CabalmailKit

/// Why the Flagged view's mail half has nothing new to show, for the line
/// above the list.
enum FlaggedMailFailure: Equatable {
    /// No page has landed for this pick: the list holds feed items only.
    case neverLoaded
    /// A refresh failed: the messages on screen are from the last one that
    /// worked.
    case refresh
    /// The next page failed: the list stops at its horizon until it is
    /// tried again.
    case nextPage
}

/// The Flagged view's mail half: every message loaded so far for one pick,
/// where the next page starts, how far down the half is whole, and what
/// became of the last request.
///
/// A value with no source in it: `FlaggedListViewModel` asks the source and
/// hands each answer here, so every rule about a page landing, a request
/// failing and a row leaving is tested without one. When the half moves
/// onto a local store (`FlaggedMailSource`) the rules stay as they are.
struct FlaggedMailHalf {
    /// The messages, in the source's order.
    private(set) var rows: [SearchedEnvelope] = []
    /// Opaque next-page cursor; nil when the source has no more.
    private(set) var cursor: String?
    /// The instant the half is complete down to (`FlaggedList.mailCutoff`):
    /// nothing vouched for until a page lands, and no horizon once the half
    /// is whole or cannot be had at all.
    private(set) var cutoff: Date? = FlaggedList.nothingYet
    /// The source stopped at its cap: some matches are in no page.
    private(set) var truncated = false
    private(set) var failure: FlaggedMailFailure?
    /// The failure in words.
    private(set) var failureMessage: String?
    /// How many messages the pick matched, as its first page said.
    private var total: Int?
    /// How many rows the source has put in `rows` since the list began.
    private var delivered = 0
    /// Rows a removal took, with where they sat: a refused removal puts
    /// its row back.
    private var removed: [MessageRef: (row: SearchedEnvelope, index: Int)] = [:]

    // MARK: Requests

    /// A request is going out: the last one's failure no longer stands.
    mutating func beginLoad() {
        failure = nil
        failureMessage = nil
    }

    /// A page landed. A first page replaces what was loaded, so a refresh
    /// keeps the old rows on screen until this moment; a later page is
    /// appended. A page boundary that shifts under mailbox churn can
    /// deliver a message twice; the list shows it once all the same
    /// (`FlaggedList.merge`), and the count is unmoved, since it is taken
    /// from what was delivered and what of that still matches.
    mutating func land(_ page: FlaggedMailPage, reset: Bool) {
        let fresh = page.rows
        if reset {
            rows = fresh
            delivered = fresh.count
            total = page.total
            truncated = page.truncated
            removed = [:]
        } else {
            rows += fresh
            delivered += fresh.count
            truncated = truncated || page.truncated
        }
        cursor = page.nextCursor
        cutoff = FlaggedList.mailCutoff(loaded: rows.map(\.envelope), hasMore: page.nextCursor != nil)
    }

    /// A request failed. With no page ever loaded there is no claim to make
    /// about mail, and the feed half stands alone; otherwise the rows and
    /// the horizon stay as they were.
    mutating func fail(_ error: any Error, reset: Bool) {
        if !reset {
            failure = .nextPage
        } else if rows.isEmpty {
            failure = .neverLoaded
            cutoff = nil
            cursor = nil
        } else {
            failure = .refresh
        }
        failureMessage = error.localizedDescription
    }

    // MARK: Rows

    func row(for ref: MessageRef) -> SearchedEnvelope? {
        rows.first { $0.ref == ref }
    }

    /// The rows the pick still finds: one whose flag was cleared stays
    /// loaded, so that setting the flag again brings it back, and is left
    /// out of the list meanwhile.
    func matching(_ criterion: FlagCriterion) -> [SearchedEnvelope] {
        rows.filter { criterion.matches($0.envelope.flags) }
    }

    /// How many messages the pick finds: the first page's count, less the
    /// rows delivered since that have left the list. Nil until the half
    /// has answered.
    func count(matching criterion: FlagCriterion) -> Int? {
        total.map { max(0, $0 - (delivered - matching(criterion).count)) }
    }

    /// Sets or clears `flag` on the rows `refs` names. Returns whether any
    /// row changed.
    mutating func applyFlag(_ flag: Flag, added: Bool, to refs: Set<MessageRef>) -> Bool {
        var changed = false
        rows = rows.map { row in
            guard refs.contains(row.ref), row.envelope.flags.contains(flag) != added else { return row }
            var flags = row.envelope.flags
            if added { flags.insert(flag) } else { flags.remove(flag) }
            changed = true
            return SearchedEnvelope(envelope: row.envelope.withFlags(flags), folder: row.folder)
        }
        return changed
    }

    /// The messages `refs` names left their folders. Returns the ones this
    /// half listed.
    mutating func remove(_ refs: Set<MessageRef>) -> Set<MessageRef> {
        var taken = Set<MessageRef>()
        for (index, row) in rows.enumerated() where refs.contains(row.ref) {
            removed[row.ref] = (row, index)
            taken.insert(row.ref)
        }
        if !taken.isEmpty { rows.removeAll { taken.contains($0.ref) } }
        return taken
    }

    /// A removal was refused: its row goes back where it sat, read or
    /// unread as the server left it. Returns whether a row came back.
    mutating func restore(_ ref: MessageRef, seen: Bool? = nil) -> Bool {
        guard let taken = removed.removeValue(forKey: ref), row(for: ref) == nil else { return false }
        var row = taken.row
        if let seen {
            var flags = row.envelope.flags
            if seen { flags.insert(.seen) } else { flags.remove(.seen) }
            row = SearchedEnvelope(envelope: row.envelope.withFlags(flags), folder: row.folder)
        }
        rows.insert(row, at: min(taken.index, rows.count))
        return true
    }
}
