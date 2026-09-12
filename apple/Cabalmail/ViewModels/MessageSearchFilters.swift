import Foundation

/// Structured filter form state for the message-list search.
///
/// Mirrors the React webmail's filter sidebar
/// (`react/admin/src/Email/Search/index.jsx`): `from`, `to`, `subject`,
/// `since`, `before`, `unread`, `flagged`, `has_attachment`, and a
/// `this_folder_only` scope toggle. The view model snapshots this struct
/// into a `SearchQuery` on every `runSearch()` call, so flipping a filter
/// re-issues the request the next time the user submits.
///
/// Default = "no filters set" — every text field empty, every flag off,
/// `thisFolderOnly == false` so the default scope is cross-folder
/// (matching the React UX).
struct MessageSearchFilters: Sendable, Equatable {
    var from: String = ""
    var to: String = ""
    var subject: String = ""
    var since: Date?
    var before: Date?
    var unread: Bool = false
    var flagged: Bool = false
    var hasAttachment: Bool = false
    var thisFolderOnly: Bool = false

    /// `true` when nothing here can narrow a result set — every text field
    /// empty and every flag off. Used by `runSearch()` to drop back to the
    /// folder view when the user submits an empty free-text query with no
    /// filters set.
    ///
    /// `thisFolderOnly` deliberately doesn't count: it's a scope, not a
    /// predicate, and scoping "everything" to one folder is the folder view
    /// itself. Counting it made an emptied query with the toggle still on a
    /// runnable search, which drew the whole mailbox as matches (#1536).
    var hasNoPredicate: Bool {
        from.isEmpty
            && to.isEmpty
            && subject.isEmpty
            && since == nil
            && before == nil
            && !unread
            && !flagged
            && !hasAttachment
    }

    /// Number of non-default filter values. Drives the "Filters · 3"
    /// badge so the user can see at a glance whether any filters are in
    /// play without opening the panel. `thisFolderOnly` counts because
    /// it's still a scope change away from the default.
    var activeCount: Int {
        var count = 0
        if !from.isEmpty { count += 1 }
        if !to.isEmpty { count += 1 }
        if !subject.isEmpty { count += 1 }
        if since != nil { count += 1 }
        if before != nil { count += 1 }
        if unread { count += 1 }
        if flagged { count += 1 }
        if hasAttachment { count += 1 }
        if thisFolderOnly { count += 1 }
        return count
    }
}
