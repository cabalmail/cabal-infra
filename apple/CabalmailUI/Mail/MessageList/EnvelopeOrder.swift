import Foundation
import CabalmailKit

/// The order a folder list shows its rows in under a sort criterion: the
/// comparator the merge, hydrate and restore paths hand to `sort(by:)`.
///
/// The Lambda sorts each page server-side in the same criterion, so the top
/// page holds the rows that belong at the top; this orders the rows the list
/// merges from several pages and its cache. Equal keys fall back to the
/// higher UID first, so rows with the same sender, subject or date keep one
/// order between sorts.
struct EnvelopeOrder: Equatable, Sendable {
    let criterion: SortCriterion

    init(_ criterion: SortCriterion) {
        self.criterion = criterion
    }

    /// True when `lhs` should sort before `rhs` in the visible list.
    func precedes(_ lhs: Envelope, _ rhs: Envelope) -> Bool {
        let ascending = criterion.direction == .ascending
        switch criterion.field {
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
