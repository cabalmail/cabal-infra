import Foundation
import CabalmailKit

/// What the feed half of a search does with the term and filters the mail
/// half was given (flags-and-cross-media.md, decision 17).
///
/// Four of search's filters mean the same thing for an article as for a
/// message: Unread, the flag, Since and Before (by the day it was
/// published). The rest describe a message, and no article can satisfy
/// them, so with one set the feed half does not search at all, and says
/// which filter stops it.
enum FeedSearchPlan: Equatable {
    /// No term and no filter that applies: nothing has been asked.
    case nothing
    /// A filter only a message can pass is set.
    case blocked([MailOnlyFilter])
    case search(RssStore.ItemSearch)

    /// The filters that narrow mail alone, in the filter sheet's order.
    enum MailOnlyFilter: String, CaseIterable, Sendable {
        case from = "From"
        case to = "To"
        case subject = "Subject"
        case hasAttachment = "Has attachment"
        case thisFolderOnly = "This folder only"
    }

    init(text: String, filters: MessageSearchFilters) {
        let blocking = Self.mailOnly(in: filters)
        guard blocking.isEmpty else {
            self = .blocked(blocking)
            return
        }
        // The built-in flag's toggle and a list's flag pick are one
        // criterion here, as they are one condition on the server.
        let flag = filters.flag ?? (filters.flagged ? .slot(FlagPalette.systemSlot) : nil)
        let search = RssStore.ItemSearch(
            text: text.trimmingCharacters(in: .whitespaces), unread: filters.unread, flag: flag,
            since: filters.since, before: filters.before
        )
        self = search.hasPredicate ? .search(search) : .nothing
    }

    static func mailOnly(in filters: MessageSearchFilters) -> [MailOnlyFilter] {
        var found: [MailOnlyFilter] = []
        if !filters.from.isEmpty { found.append(.from) }
        if !filters.to.isEmpty { found.append(.to) }
        if !filters.subject.isEmpty { found.append(.subject) }
        if filters.hasAttachment { found.append(.hasAttachment) }
        if filters.thisFolderOnly { found.append(.thisFolderOnly) }
        return found
    }

    /// `filters` with every mail-only one put back to its default, so the
    /// feed half can search again: what the blocked line's button does.
    static func clearingMailOnly(_ filters: MessageSearchFilters) -> MessageSearchFilters {
        var cleared = filters
        cleared.from = ""
        cleared.to = ""
        cleared.subject = ""
        cleared.hasAttachment = false
        cleared.thisFolderOnly = false
        return cleared
    }

    /// What the search reads, when it reads anything.
    var search: RssStore.ItemSearch? {
        if case .search(let search) = self { return search }
        return nil
    }
}
