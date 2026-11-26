import Foundation
import CabalmailKit

/// One page of the flagged mail the Flagged view lists.
struct FlaggedMailPage: Equatable, Sendable {
    /// The page's messages, each in its own folder, in the source's order.
    var rows: [SearchedEnvelope]
    /// How many messages the criterion matches in all. Read from a first
    /// page only: a later page of the server's search counts only the
    /// matches on or before its cursor's day.
    var total: Int
    /// Where the next page starts; nil when this is the last.
    var nextCursor: String?
    /// The source stopped at its cap: some matches are in no page.
    var truncated: Bool

    static let empty = FlaggedMailPage(rows: [], total: 0, nextCursor: nil, truncated: false)
}

/// Where the Flagged view's mail half comes from: a flag criterion and a
/// cursor in, a page out.
///
/// The one seam between the view and its mail. Today's source pages the
/// server's cross-folder search (`SearchFlaggedMailSource`), online only.
/// When `docs/1.x/post-wave-3/sqlite-mail-store.md`'s PR 5.1 lands, a source
/// over that store's cross-folder flagged query takes its place, and
/// nothing else of the view changes. That query has to answer every
/// criterion this is asked for: the built-in flag, one custom slot, and any
/// flag.
protocol FlaggedMailSource: Sendable {
    func page(matching criterion: FlagCriterion, after cursor: String?) async throws -> FlaggedMailPage
}

/// Flagged mail from `/search_envelopes` with no folder, which searches
/// every subscribed folder but Trash.
///
/// The server orders the matches by the day they arrived and, inside a day,
/// by folder and UID; its cursor holds no state, so every page searches
/// every folder again, which is why a page asks for the server's most. Past
/// 5,000 matches the server leaves out whole folders late in its walk, so a
/// truncated answer cannot be completed by paging.
struct SearchFlaggedMailSource: FlaggedMailSource {
    let imap: any ImapClient
    var pageSize = FlaggedList.mailPageSize

    func page(matching criterion: FlagCriterion, after cursor: String?) async throws -> FlaggedMailPage {
        guard let query = Self.query(for: criterion) else { return .empty }
        let result = try await imap.searchEnvelopes(query.page(limit: pageSize, cursor: cursor))
        return FlaggedMailPage(
            rows: result.envelopes, total: result.totalEstimate, nextCursor: result.nextCursor,
            truncated: result.truncated
        )
    }

    /// What a criterion asks the server for, and nothing else: the built-in
    /// flag as `flagged`, a flag of the user's own as its `keyword` slot,
    /// any flag as `any_flag`. Nil for a string that is no slot, which the
    /// server would refuse and no message can carry.
    static func query(for criterion: FlagCriterion) -> SearchQuery? {
        if criterion == .any { return SearchQuery(anyFlag: true) }
        if criterion.isSystemFlag { return SearchQuery(flagged: true) }
        return criterion.keywordSlot.map { SearchQuery(keyword: $0) }
    }
}
