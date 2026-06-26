import SwiftUI
import CabalmailKit

// Search-mode UI helpers for `MessageListView`. Same-module extension so
// the primary view body stays under SwiftLint's `type_body_length` cap
// while the search bits — filter toolbar button, filter sheet, in-list
// match-count banner — live alongside the rest of the view.
extension MessageListView {
    /// Toolbar button that opens the filter sheet. Shows a badge with
    /// the active-filter count so the user can see at a glance whether
    /// any filters are in play. Disabled until the view model boots so
    /// taps don't surface a half-initialized sheet during the very
    /// first render.
    @ViewBuilder
    var filterButton: some View {
        Button {
            filtersPresented = true
        } label: {
            Label("Filters", systemImage: filterButtonIcon)
                .labelStyle(.iconOnly)
        }
        .disabled(model == nil)
        .accessibilityLabel(filterButtonAccessibilityLabel)
    }

    private var filterButtonIcon: String {
        guard let model, model.searchFilters.activeCount > 0 else {
            return "line.3.horizontal.decrease.circle"
        }
        return "line.3.horizontal.decrease.circle.fill"
    }

    private var filterButtonAccessibilityLabel: String {
        let active = model?.searchFilters.activeCount ?? 0
        if active == 0 { return "Filters" }
        return "Filters, \(active) active"
    }

    /// Filter sheet — only constructs the inner view when the model is
    /// available so the sheet's `@State` snapshots a fully-formed
    /// `searchFilters` value rather than the default-initialized one.
    @ViewBuilder
    var filtersSheet: some View {
        if let model {
            @Bindable var bindable = model
            SearchFiltersSheet(
                filters: $bindable.searchFilters,
                currentFolderName: folder.name,
                // The global search surface has no anchor folder to scope to,
                // so it hides the "This folder only" toggle.
                allowFolderScope: !isSearchScope,
                onApply: { snapshot in
                    bindable.searchFilters = snapshot
                    filtersPresented = false
                    // The sheet defines a full structured search ("All" mode),
                    // even when opened while a filter pill is active. Clear the
                    // pill's filterTab and pass resetFilterTab: false so
                    // runSearch keeps the snapshot we just applied instead of
                    // mistaking this for a pill->text transition and wiping it.
                    bindable.filterTab = .all
                    Task { await bindable.runSearch(resetFilterTab: false) }
                },
                onCancel: {
                    filtersPresented = false
                }
            )
        }
    }

    /// In-list banner shown above the message list while a search is
    /// active. Mirrors the React webmail's search header: scope label
    /// ("in N folders" or the folder name), match count with truncation
    /// hint, and a clear button that drops back to the folder view.
    @ViewBuilder
    func searchMetadataBanner(model: MessageListViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(searchScopeLabel(model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(searchMatchLabel(model))
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Button {
                Task { await model.clearSearch() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.thinMaterial)
    }

    private func searchScopeLabel(_ model: MessageListViewModel) -> String {
        let folders = model.searchFoldersSearched
        if model.searchFilters.thisFolderOnly {
            return "in \(folders.first ?? folder.name)"
        }
        if folders.isEmpty { return "in all folders" }
        if folders.count == 1 { return "in \(folders[0])" }
        return "in \(folders.count) folders"
    }

    private func searchMatchLabel(_ model: MessageListViewModel) -> String {
        let shown = model.envelopes.count
        let total = model.searchTotalEstimate
        if model.searchTruncated {
            return "Showing first \(shown) of \(total)+ matches — refine your query"
        }
        let noun = total == 1 ? "match" : "matches"
        return "\(shown) of \(total) \(noun)"
    }
}
