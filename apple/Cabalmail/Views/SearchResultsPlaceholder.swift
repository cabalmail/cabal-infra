import SwiftUI

/// What the search results area says when it has no rows to show.
///
/// Search is submit-driven — a term does nothing until Return — so "no rows"
/// covers two states that look identical and mean opposite things: a query
/// that has not been sent yet, and one that was sent and matched nothing.
/// A plain value so the distinction is stated once and testable without
/// driving the UI.
enum SearchResultsPlaceholder: Equatable, CaseIterable {
    /// Rows are showing, this isn't the search surface, or there is nothing
    /// useful to say (a pristine field, a load in flight, an error already on
    /// screen).
    case hidden
    /// A term is typed but has not been submitted. Nothing has been searched,
    /// so an empty list is not an answer.
    case pressReturn
    /// The submitted term came back with nothing. The honest empty state.
    case noMatches

    init(
        isSearchScope: Bool,
        query: String,
        submittedQuery: String,
        isLoading: Bool,
        hasError: Bool,
        visibleRowCount: Int
    ) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard isSearchScope, visibleRowCount == 0, !isLoading, !hasError else {
            self = .hidden
            return
        }
        // A pristine field is left alone: the user has just arrived at the
        // search surface and the prompt in the field already says what to do.
        guard !trimmed.isEmpty else {
            self = .hidden
            return
        }
        self = trimmed == submittedQuery ? .noMatches : .pressReturn
    }

    var title: String {
        switch self {
        case .hidden: return ""
        case .pressReturn: return "Press Return to search"
        case .noMatches: return "No matches"
        }
    }

    /// Second line. Names the term for `.noMatches` so a stale-looking empty
    /// list says which query it belongs to.
    func message(for query: String) -> String {
        switch self {
        case .hidden:
            return ""
        case .pressReturn:
            return "Nothing has been searched yet."
        case .noMatches:
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty
                ? "No messages matched your search."
                : "No messages matched \u{201C}\(trimmed)\u{201D}."
        }
    }
}

extension MessageListView {
    /// Overlaid on the results list; empty when there is nothing to say, so
    /// the folder list and a populated search are untouched.
    @ViewBuilder
    func searchResultsPlaceholder(
        model: MessageListViewModel,
        visibleRowCount: Int
    ) -> some View {
        let placeholder = SearchResultsPlaceholder(
            isSearchScope: isSearchScope,
            query: model.searchQuery,
            submittedQuery: model.submittedQuery,
            isLoading: model.isLoading,
            hasError: model.errorMessage != nil,
            visibleRowCount: visibleRowCount
        )
        if placeholder != .hidden {
            ContentUnavailableView(
                placeholder.title,
                systemImage: "magnifyingglass",
                description: Text(placeholder.message(for: model.searchQuery))
            )
        }
    }
}
