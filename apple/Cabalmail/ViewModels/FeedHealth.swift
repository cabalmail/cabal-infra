import Foundation
import CabalmailKit

/// The fetcher's view of a feed, reduced to what a sidebar badge can say
/// (RSS plan, phase 10, pulled forward 2026-09-10 after an OPML import
/// left two silently empty feeds). Thresholds match the plan: three
/// consecutive failures is worth a warning; twenty, or a dead letter, means
/// the fetcher has stopped trying.
enum FeedHealthLevel: Equatable {
    case healthy
    case failing(Int)
    case stopped

    var symbol: String? {
        switch self {
        case .healthy: return nil
        case .failing: return "exclamationmark.triangle.fill"
        case .stopped: return "xmark.octagon.fill"
        }
    }

    /// Short wording for the badge's accessibility label and tooltip.
    var summary: String? {
        switch self {
        case .healthy: return nil
        case .failing(let count): return "Failing: \(count) fetches in a row"
        case .stopped: return "Stopped: the fetcher gave up on this feed"
        }
    }
}

enum FeedHealth {
    static let warningThreshold = 3
    static let stoppedThreshold = 20

    static func level(for feed: RssFeedSummary?) -> FeedHealthLevel {
        guard let feed else { return .healthy }
        if feed.deadLettered || feed.consecutiveFailureCount >= stoppedThreshold { return .stopped }
        if feed.consecutiveFailureCount >= warningThreshold { return .failing(feed.consecutiveFailureCount) }
        return .healthy
    }

    /// One line for the item list's header while a feed is unwell: the
    /// level, then the fetcher's own words when it left any.
    static func headline(for feed: RssFeedSummary?) -> String? {
        guard let feed, let summary = level(for: feed).summary else { return nil }
        let detail = feed.lastError.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? summary : "\(summary). \(detail)"
    }
}
