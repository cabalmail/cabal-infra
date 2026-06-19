import SwiftUI
import CabalmailKit

/// Client-side narrowing of the loaded envelopes — the three tabs the
/// React webmail shows (`react/admin/src/Email/Messages/index.jsx`),
/// translated to a SwiftUI segmented control.
public enum MessageFilter: String, CaseIterable, Identifiable {
    case all
    case unread
    case flagged

    public var id: String { rawValue }

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
    @ViewBuilder
    func filterTabsBar(model: MessageListViewModel, searchActive: Bool) -> some View {
        @Bindable var bindable = model
        HStack(spacing: 6) {
            ForEach(MessageFilter.allCases) { filter in
                Button {
                    bindable.filterTab = filter
                } label: {
                    HStack(spacing: 4) {
                        Text(filter.label)
                            .font(.subheadline.weight(filter == model.filterTab ? .semibold : .regular))
                        Text("\(pillCount(filter, model: model))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(filter == model.filterTab
                                  ? Color.accentColor.opacity(0.18)
                                  : Color.clear)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(filter.label), \(pillCount(filter, model: model))")
            }
            Spacer()
            // Right-side controls live with the filter tabs so list-
            // shaping actions sit one row above the list rather than at
            // the far edge of the window toolbar. The search-refinement
            // filter button only surfaces while the user is engaged with
            // the search field — see `topInset` in MessageListView.swift
            // for the cross-platform focus / `isSearching` routing.
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
        if model.isSearchActive {
            return model.envelopes.filter { filter.includes($0) }.count
        }
        switch filter {
        case .all:     return Int(model.totalMessages)
        case .unread:  return model.unseen
        case .flagged: return model.flagged
        }
    }

    /// The list's top inset: the macOS inline search field, the search-result
    /// metadata banner, the address-filter chip, and the filter tabs bar.
    /// Lives here alongside the filter UI it mostly renders.
    @ViewBuilder
    func topInset(model: MessageListViewModel) -> some View {
        VStack(spacing: 0) {
            #if os(macOS)
            inlineSearchField(model: model, focused: $inlineSearchFocused)
            #endif
            if model.isSearchActive {
                searchMetadataBanner(model: model)
            }
            if let addressFilter, !addressFilter.isEmpty {
                addressFilterChip(addressFilter)
            }
            // The filter button is search refinement, not list filtering,
            // so it only surfaces once the user is engaged with the
            // search field — preventing the conceptual collision with
            // the All / Unread / Flagged pills next to it. macOS uses
            // our own @FocusState on the inline TextField; everywhere
            // else reads `\.isSearching` from the `.searchable` scope.
            #if os(macOS)
            filterTabsBar(
                model: model,
                searchActive: inlineSearchFocused || model.isSearchActive
            )
            #else
            SearchActiveScope { isSearching in
                filterTabsBar(model: model, searchActive: isSearching)
            }
            #endif
        }
    }
}

/// Thin wrapper that reads `\.isSearching` from inside the `.searchable`
/// scope and hands it to a child view. `@Environment(\.isSearching)`
/// returns a meaningful value only when read from a view rendered
/// underneath the `.searchable` modifier; reading it on `MessageListView`
/// itself (which is where the modifier is applied) always returns false.
/// Used by `topInset` on every non-macOS platform to gate the search-
/// refinement filter button.
struct SearchActiveScope<Content: View>: View {
    @Environment(\.isSearching) private var isSearching
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(isSearching) }
}
