import Foundation

/// What the Mail section of a search's results has to show: its rows, or
/// the one line that stands in for them. Pure, so each state is stated
/// once and a test can ask for it without a view.
enum MailSectionStatus: Equatable {
    /// Nothing has been sent to the server for this search.
    case idle
    /// The first request is out and no row has landed.
    case searching
    /// The request failed with no rows to fall back on.
    case failed(offline: Bool)
    /// The search answered with nothing.
    case empty
    /// Rows are loaded. `total` is the search's whole count as the server
    /// gave it, `truncated` that the server stopped counting at its cap,
    /// and `stale` that a refresh of these rows failed.
    case rows(total: Int, truncated: Bool, stale: Bool)

    init(
        isActive: Bool, isLoading: Bool, hasError: Bool, isOffline: Bool, rowCount: Int, total: Int,
        truncated: Bool
    ) {
        if rowCount > 0 {
            self = .rows(total: max(total, rowCount), truncated: truncated, stale: hasError)
        } else if isLoading {
            self = .searching
        } else if hasError {
            self = .failed(offline: isOffline)
        } else {
            self = isActive ? .empty : .idle
        }
    }

    /// Whether the section has answered with no rows: what the screen's
    /// one "No matches" stands on when the other section is empty too.
    var isEmpty: Bool { self == .empty }
}

/// The Feeds section's counterpart.
enum FeedSectionStatus: Equatable {
    /// Nothing has been asked of the feed store for this search.
    case idle
    /// A filter only a message can pass is set, so feeds are not searched.
    case blocked([FeedSearchPlan.MailOnlyFilter])
    /// The feed store could not be read.
    case unreadable
    case empty
    case rows(total: Int)

    init(plan: FeedSearchPlan?, loaded: Bool, failed: Bool, rowCount: Int, total: Int) {
        switch plan {
        case nil, .nothing?:
            self = .idle
        case .blocked(let filters)?:
            self = .blocked(filters)
        case .search?:
            if failed {
                self = .unreadable
            } else if rowCount > 0 {
                self = .rows(total: max(total, rowCount))
            } else {
                self = loaded ? .empty : .idle
            }
        }
    }

    var isEmpty: Bool { self == .empty }
}

/// The words of a search's sectioned results.
enum SearchSectionWords {
    /// How many of a section's matches All lists before its Show all row.
    static let digestLimit = 5

    static let mailTitle = "Mail"
    static let feedsTitle = "Feeds"

    static let searchingMail = "Searching mail\u{2026}"
    static let mailEmpty = "No messages matched."
    static let mailStale = "Mail results could not be refreshed."
    static let feedsEmpty = "No downloaded articles matched."
    static let feedsUnreadable = "Feed results could not be read."
    /// The feed half's reach, said wherever feed results are listed.
    static let feedCoverage = "Feed results cover the articles downloaded to this device."

    static func mailFailed(offline: Bool) -> String {
        offline ? "Searching mail needs a connection." : "Mail could not be searched."
    }

    /// The number beside a section's title. A search the server stopped
    /// counting says so rather than passing its cap off as the total.
    static func count(_ total: Int, truncated: Bool = false) -> String {
        let number = total.formatted(.number)
        return truncated ? "\(number)+" : number
    }

    /// The row under a section's first matches that moves the control to
    /// its medium; nil when All already lists every match.
    static func showAllMail(total: Int, truncated: Bool) -> String? {
        guard total > digestLimit || truncated else { return nil }
        return truncated ? "Show all messages" : "Show all \(total.formatted(.number)) messages"
    }

    static func showAllFeeds(total: Int) -> String? {
        guard total > digestLimit else { return nil }
        return "Show all \(total.formatted(.number)) articles"
    }

    /// Why the feed half did not search: the filters only a message can
    /// pass, by the names the filter sheet gives them.
    static func feedsBlocked(by filters: [FeedSearchPlan.MailOnlyFilter]) -> String {
        let names = SearchScopeSummary.phrase(for: filters.map(\.rawValue))
        return "Feeds are not searched while \(names) \(filters.count == 1 ? "is" : "are") set."
    }

    /// The screen's one empty state, when every section in scope answered
    /// with nothing: which media were asked, and of the term.
    static func nothingMatched(_ term: String, scope: SearchScope) -> String {
        let what: String
        switch scope {
        case .all: what = "No messages or downloaded articles"
        case .mail: what = "No messages"
        case .feeds: what = "No downloaded articles"
        }
        return term.isEmpty ? "\(what) matched your search." : "\(what) matched \u{201C}\(term)\u{201D}."
    }
}
