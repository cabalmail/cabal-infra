import Foundation

/// One row of the Flagged view: a message or a feed item, under one identity.
public enum FlaggedRow: Hashable, Sendable, Identifiable {
    /// A message, in the folder the search found it in.
    case mail(Envelope, MessageRef)
    case feed(RssItem)

    public var id: ItemRef { ref }

    public var ref: ItemRef {
        switch self {
        case .mail(_, let ref): return .mail(ref)
        case .feed(let item): return item.ref
        }
    }

    /// The date the row shows and is ordered by; nil when the item has none
    /// this build can read.
    public var date: Date? {
        switch self {
        case .mail(let envelope, _): return envelope.date ?? envelope.internalDate
        case .feed(let item): return FlaggedList.publishedDate(of: item)
        }
    }
}

/// The two halves of the Flagged view, for saying which one the list is
/// waiting on.
public enum FlaggedSource: Hashable, Sendable {
    case mail
    case feed
}

/// What the Flagged view shows from the rows loaded so far.
public struct FlaggedPage: Equatable, Sendable {
    /// The rows to draw, newest first.
    public let rows: [FlaggedRow]
    /// The horizon: nil once both halves are whole, otherwise the instant
    /// the list is complete down to.
    public let cutoff: Date?
    /// The half whose next page moves the horizon; nil with no horizon.
    public let next: FlaggedSource?
    /// How many loaded rows are older than the horizon and wait for that
    /// page.
    public let heldBack: Int

    public init(rows: [FlaggedRow], cutoff: Date?, next: FlaggedSource?, heldBack: Int) {
        self.rows = rows
        self.cutoff = cutoff
        self.next = next
        self.heldBack = heldBack
    }
}

/// The Flagged view's one list (`docs/1.x/cross-media-ux-plan.md`, Phase
/// 5): flagged messages and flagged feed items together, newest first, each
/// ordered by the date its row shows. The Swift sibling of the Android
/// kit's `FlaggedList`, with the same rule.
///
/// The two halves arrive differently. Feed items are on the device.
/// Messages come from the server's cross-folder search a page at a time,
/// ordered by the day they arrived and, inside a day, by folder and UID,
/// not by time. Interleaving a whole half with a partial one would show an
/// old feed item under a gap where unloaded mail belongs, so the list stops
/// at a horizon: while a half has more to load, nothing older than the
/// point that half is complete down to is shown from either, and the rows
/// past it wait for the next page.
///
/// For mail that point is a day. A page ends partway through an arrival
/// day, so the half is whole only from the following midnight (UTC, where
/// the server takes its days). It is exact where an envelope carries the
/// day it arrived (`internalDate`); the API's envelopes carry the Date
/// header in its place, so a message whose two dates are more than a day
/// apart can land a page late, in its right place. For feed items the point
/// is the last row read.
///
/// A half that pages needs this whatever it pages from, so the rule stays
/// when the mail half moves onto a local store.
public enum FlaggedList {
    /// Messages a request, the server's most: its cursor holds no state, so
    /// every request searches every folder again, and few large pages are
    /// the cheap shape.
    public static let mailPageSize = 200

    /// Feed items a read from the device's store.
    public static let feedPageSize = 200

    /// "Nothing can be vouched for yet": the horizon while pages are left
    /// and no dated row has loaded.
    public static let nothingYet = Date.distantFuture

    /// The instant the mail half is complete down to, given everything
    /// loaded so far in the server's order: nil when no page is left. With
    /// pages left it is the midnight (UTC) after the last dated row's day;
    /// with no dated row loaded, nothing can be vouched for yet.
    public static func mailCutoff(loaded: [Envelope], hasMore: Bool) -> Date? {
        guard hasMore else { return nil }
        guard let last = loaded.reversed().lazy.compactMap({ $0.internalDate ?? $0.date }).first else {
            return nothingYet
        }
        let day = utc.startOfDay(for: last)
        return utc.date(byAdding: .day, value: 1, to: day) ?? nothingYet
    }

    /// The instant the feed half is complete down to, given everything read
    /// so far, newest first: nil when the store has no more. With more to
    /// read it is just past the last dated row, since an item published in
    /// the same instant may be on the next read.
    public static func feedCutoff(loaded: [RssItem], hasMore: Bool) -> Date? {
        guard hasMore else { return nil }
        guard let last = loaded.reversed().lazy.compactMap(publishedDate(of:)).first else { return nothingYet }
        return Date(timeIntervalSinceReferenceDate: last.timeIntervalSinceReferenceDate.nextUp)
    }

    /// One list from both halves, newest first, cut at the later of the two
    /// horizons. A row with no date sorts last, and so shows only once both
    /// halves are whole. A message is one ref, however many pages deliver
    /// it.
    public static func merge(
        mail: [SearchedEnvelope], mailCutoff: Date?, feed: [RssItem], feedCutoff: Date?
    ) -> FlaggedPage {
        var seen = Set<ItemRef>()
        let all = (mail.map { FlaggedRow.mail($0.envelope, $0.ref) } + feed.map(FlaggedRow.feed))
            .filter { seen.insert($0.ref).inserted }
        let cutoff = [mailCutoff, feedCutoff].compactMap { $0 }.max()
        let next: FlaggedSource?
        if let cutoff {
            next = cutoff == mailCutoff ? .mail : .feed
        } else {
            next = nil
        }
        let shown: [FlaggedRow]
        if let cutoff {
            shown = all.filter { row in row.date.map { $0 >= cutoff } ?? false }
        } else {
            shown = all
        }
        return FlaggedPage(
            rows: shown.sorted(by: precedes), cutoff: cutoff, next: next, heldBack: all.count - shown.count
        )
    }

    /// A feed item's published date: the server's ISO 8601 timestamp, with
    /// or without a fraction; nil for anything else.
    public static func publishedDate(of item: RssItem) -> Date? {
        (try? iso.parse(item.publishedAt)) ?? (try? isoFractional.parse(item.publishedAt))
    }

    /// Newest first, the dateless last, and one fixed order among rows of
    /// one instant, so the list does not reshuffle as pages land.
    static func precedes(_ lhs: FlaggedRow, _ rhs: FlaggedRow) -> Bool {
        switch (lhs.date, rhs.date) {
        case let (left?, right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return orderKey(lhs.ref) < orderKey(rhs.ref)
        }
    }

    /// A total order over refs, for rows the dates cannot tell apart: mail
    /// before feed items, then by folder and UID, or by feed and sort key.
    private static func orderKey(_ ref: ItemRef) -> String {
        switch ref {
        case .mail(let message): return "0\u{1}\(message.folder)\u{1}\(String(format: "%010u", message.uid))"
        case .feed(let feedID, let sortKey): return "1\u{1}\(feedID)\u{1}\(sortKey)"
        }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    private static let iso = Date.ISO8601FormatStyle()
    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
