import SwiftUI
import CabalmailKit

/// The list's filter: All, Unread, or Flagged. The bar draws only the
/// Unread and Flagged pills; All is both of them off. Unread is a toggle
/// (`MessageFilter.toggling`), and so is Flagged until Settings > Flags
/// holds a flag of the user's own, when it becomes a menu of flags to
/// filter by (`FlagFilterMenuPolicy`). The enum itself lives in the kit (`MessageFilter`),
/// where `Preferences` stores each folder's sticky pill; the labels are the
/// view's, and the rule for which rows pass is `MessageListNarrowing`.
extension MessageFilter {
    /// The pill's word. The Flagged filter a folder remembers is the
    /// built-in flag's, so the plain pill carries that flag's name from
    /// Settings > Flags: rename the entry "Urgent" and the pill reads
    /// "Urgent". With a flag of the user's own in the palette the pill is a
    /// menu, and takes its word from `FlagFilterMenuPolicy`.
    public func label(palette: [FlagPaletteEntry]) -> String {
        switch self {
        case .all:     return "All"
        case .unread:  return "Unread"
        case .flagged: return FlagToggle.systemFlagName(in: palette)
        }
    }
}

// UI helpers for the filter tabs. Lives in a sibling extension so the
// primary MessageListView body stays under SwiftLint's
// `type_body_length` cap. The bar mirrors React's pill row above the
// message list: the Unread and Flagged toggles with counts.
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
                ForEach(MessageFilter.pills) { filter in
                    let identifier = "filter.pill.\(filter.rawValue)"
                    // Flagged is a menu once Settings > Flags holds a flag
                    // of the user's own (`FlagFilterMenuPolicy`).
                    if filter == .flagged, let pill = model.flagFilterPill {
                        FlagFilterPill(pill: pill, identifier: identifier) { choice in
                            Task { await model.chooseFlagFilter(choice) }
                        }
                    } else {
                        FilterPill(
                            label: filter.label(palette: model.flagPalette),
                            isOn: filter == model.filterTab,
                            count: pillCount(filter, model: model),
                            identifier: identifier
                        ) {
                            Task { await model.selectFilter(model.filterTab.toggling(filter)) }
                        }
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
        // the Unread pill collapse to the flagged-result count.
        if model.isSearchActive, model.filterTab == .all {
            return model.envelopes.filter(MessageListNarrowing(tab: filter).includes).count
        }
        switch filter {
        case .all:     return model.allCount
        case .unread:  return model.unseen
        case .flagged: return model.flagged
        }
    }

    /// The list's top inset. Folder scope shows the
    /// Unread / Flagged pills bar; the global search surface shows the
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
    /// the sort menu, and the multi-select toggle. No Unread / Flagged
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
