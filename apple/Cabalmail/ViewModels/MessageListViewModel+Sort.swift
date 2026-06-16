import Foundation
import CabalmailKit

// Sort plumbing. Lives in a sibling extension so the main view-model file
// stays under SwiftLint's 400-line cap. Two surfaces:
//
//   * `envelopeOrder(_:_:)` is the comparator the merge / hydrate paths
//     pass to `Array.sorted(by:)`. It dispatches on `sortCriterion`, with
//     a UID-descending tiebreaker so equal-key envelopes (multiple
//     messages from the same address, identical subjects after stripping
//     "Re:") order deterministically.
//
//   * `setSort(_:)` is the one entry point UI calls when the user picks
//     a different sort. It wipes in-memory state (sort is a top-of-list
//     reshuffle, not a filter — pagination state is per-sort) and
//     re-fetches the top page in the new order.
//
// The Lambda sort happens server-side: `ApiBackedImapClient.envelopes`
// and `topEnvelopes` pass `sortCriterion`'s wire form to `/list_messages`,
// so the top page actually contains the items that belong at the top of
// the user's view. Client-side sorting handles the merge of cached +
// just-fetched envelopes and the post-paginate re-shuffle when older
// pages arrive.
extension MessageListViewModel {
    /// Switch the active sort and reload. No-op when the criterion
    /// doesn't change so UI repeat-clicks don't burn a refresh.
    func setSort(_ criterion: SortCriterion) async {
        guard sortCriterion != criterion else { return }
        dbg("setSort \(criterion.field)")
        sortCriterion = criterion
        envelopes.removeAll()
        sourceFolderByUID = [:]
        await refresh()
    }

    /// Comparator used by `mergeFetched` / `hydrateFromCache`. The order
    /// returns `true` when `lhs` should sort BEFORE `rhs` in the visible
    /// list.
    func envelopeOrder(_ lhs: Envelope, _ rhs: Envelope) -> Bool {
        let ascending = sortCriterion.direction == .ascending
        switch sortCriterion.field {
        case .dateReceived:
            return compareDates(lhs.internalDate ?? lhs.date,
                                rhs.internalDate ?? rhs.date,
                                ascending: ascending,
                                tiebreakers: lhs, rhs)
        case .dateSent:
            return compareDates(lhs.date, rhs.date,
                                ascending: ascending,
                                tiebreakers: lhs, rhs)
        case .from:
            return compareStrings(
                addressSortKey(lhs.from.first),
                addressSortKey(rhs.from.first),
                ascending: ascending,
                tiebreakers: lhs, rhs
            )
        case .subject:
            return compareStrings(
                subjectSortKey(lhs.subject),
                subjectSortKey(rhs.subject),
                ascending: ascending,
                tiebreakers: lhs, rhs
            )
        }
    }

    private func compareDates(
        _ lhs: Date?,
        _ rhs: Date?,
        ascending: Bool,
        tiebreakers lhsEnvelope: Envelope,
        _ rhsEnvelope: Envelope
    ) -> Bool {
        // Missing dates sort to the end regardless of direction — there's
        // no useful answer for "is nil before or after February 12th."
        switch (lhs, rhs) {
        case let (.some(left), .some(right)):
            if left == right {
                return lhsEnvelope.uid > rhsEnvelope.uid
            }
            return ascending ? left < right : left > right
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil):
            return lhsEnvelope.uid > rhsEnvelope.uid
        }
    }

    private func compareStrings(
        _ lhs: String,
        _ rhs: String,
        ascending: Bool,
        tiebreakers lhsEnvelope: Envelope,
        _ rhsEnvelope: Envelope
    ) -> Bool {
        let order = lhs.localizedCaseInsensitiveCompare(rhs)
        if order == .orderedSame {
            return lhsEnvelope.uid > rhsEnvelope.uid
        }
        let wantsAscending = ascending ? order == .orderedAscending : order == .orderedDescending
        return wantsAscending
    }

    private func addressSortKey(_ address: EmailAddress?) -> String {
        guard let address else { return "" }
        if let name = address.displayName, !name.isEmpty { return name }
        return "\(address.mailbox)@\(address.host)"
    }

    /// "Re:" / "Fwd:" prefixes shouldn't drive subject sort — strip them
    /// before comparing so a reply chain stays grouped with its parent.
    /// Matches the React webmail's behavior (`react/admin/src/Email/...`
    /// strips the prefix in the same spirit).
    private func subjectSortKey(_ subject: String?) -> String {
        guard var trimmed = subject?.trimmingCharacters(in: .whitespaces),
              !trimmed.isEmpty else { return "" }
        let prefixes = ["re:", "fw:", "fwd:"]
        var changed = true
        while changed {
            changed = false
            let lower = trimmed.lowercased()
            for prefix in prefixes where lower.hasPrefix(prefix) {
                trimmed = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return trimmed
    }
}
