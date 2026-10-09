import SwiftUI
import CabalmailKit

/// The three tabs the React webmail shows
/// (`react/admin/src/Email/Messages/index.jsx`), translated to a SwiftUI
/// segmented control. The enum itself lives in the kit (`MessageFilter`),
/// where `Preferences` stores each folder's sticky pill; the labels and the
/// client-side envelope predicate are the view's.
extension MessageFilter {
    public var label: String {
        switch self {
        case .all:     return "All"
        case .unread:  return "Unread"
        case .flagged: return "Flagged"
        }
    }

    /// True when the envelope passes this filter.
    public func includes(_ envelope: Envelope) -> Bool {
        switch self {
        case .all:     return true
        case .unread:  return !envelope.flags.contains(.seen)
        case .flagged: return envelope.flags.contains(.flagged)
        }
    }
}

// UI helpers for the filter tabs. Lives in a sibling extension so the
// primary MessageListView body stays under SwiftLint's
// `type_body_length` cap. The bar mirrors React's pill row above the
// message list: three tabs with counts.
extension MessageListView {
    // Right-side controls live with the filter tabs so list-shaping
    // actions sit one row above the list rather than at the far edge of
    // the window toolbar. The search-refinement filter button only
    // surfaces while the user is engaged with the search field — see
    // `topInset` in MessageListView.swift for the cross-platform focus /
    // `isSearching` routing. The pills stack when the column is too narrow
    // for the whole row (`FilterPillStrip`).
    @ViewBuilder
    func filterTabsBar(model: MessageListViewModel, searchActive: Bool) -> some View {
        HStack(spacing: 6) {
            FilterPillStrip {
                ForEach(MessageFilter.allCases) { filter in
                    FilterPill(
                        label: filter.label,
                        isOn: filter == model.filterTab,
                        count: pillCount(filter, model: model),
                        identifier: "filter.pill.\(filter.rawValue)"
                    ) {
                        Task { await model.selectFilter(filter) }
                    }
                }
            }
            Spacer()
            if searchActive {
                filterButton
            }
            sortMenu
            selectButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Filter-pill count. Mirrors the React pills: server-sourced folder totals
    /// (STATUS messages/unseen plus the SEARCH FLAGGED count) so the number
    /// reflects the whole folder, not how many envelopes have paged in. During
    /// search the rows are search results, not the folder, so the folder totals
    /// don't apply -- fall back to counting the loaded matches.
    private func pillCount(_ filter: MessageFilter, model: MessageListViewModel) -> Int {
        // A genuine text search (filterTab == .all while searching) counts its
        // loaded results. Folder mode and a pill-driven filter keep the
        // server-sourced folder totals, so e.g. tapping Flagged doesn't make
        // the All pill collapse to the flagged-result count.
        if model.isSearchActive, model.filterTab == .all {
            return model.envelopes.filter { filter.includes($0) }.count
        }
        switch filter {
        case .all:     return model.allCount
        case .unread:  return model.unseen
        case .flagged: return model.flagged
        }
    }

    /// The list's top inset. Folder scope shows the
    /// All / Unread / Flagged pills bar; the global search surface shows the
    /// search-result metadata banner and a controls row (refine filters, sort,
    /// select). Lives here alongside the filter UI it mostly renders.
    @ViewBuilder
    func topInset(model: MessageListViewModel) -> some View {
        VStack(spacing: 0) {
            if isSearchScope {
                // A genuine text search always shows the results banner; a pill
                // filter (folder scope only) hides it unless the match set is
                // truncated. On the search surface it's always a text/structured
                // search, so show it whenever a search is active.
                if model.isSearchActive {
                    if model.filterTab == .all || model.envelopes.count < model.search.totalEstimate {
                        searchMetadataBanner(model: model)
                    }
                    searchControlsBar(model: model)
                }
            } else {
                // Folder scope has no in-list search anymore, so the refinement
                // filter button never surfaces here — pass `searchActive: false`.
                filterTabsBar(model: model, searchActive: false)
            }
        }
    }

    /// Right-side controls for the global search surface: the structured-filter
    /// button (always available here — refining the query is the surface's job),
    /// the sort menu, and the multi-select toggle. No All / Unread / Flagged
    /// pills: those are a folder concept, and the search filter sheet already
    /// carries Unread / Flagged toggles.
    @ViewBuilder
    private func searchControlsBar(model: MessageListViewModel) -> some View {
        HStack(spacing: 6) {
            filterButton
            Spacer()
            sortMenu
            selectButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
