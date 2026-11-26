import SwiftUI
import CabalmailKit

/// The Mail section's rows under All: the search's first matches and the
/// row that shows the rest, or the one line that stands in for them while
/// the request is out, when it failed, or when it found nothing.
struct SearchMailSectionRows: View {
    let status: MailSectionStatus
    let model: MessageListViewModel
    let place: SearchPlace
    let actions: SearchRowActions

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .searching:
            HStack(spacing: 8) {
                ProgressView()
                Text(SearchSectionWords.searchingMail)
            }
            .searchSectionNote("search.mail.searching")
        case .failed(let offline):
            HStack {
                Text(SearchSectionWords.mailFailed(offline: offline))
                Spacer()
                Button("Retry") {
                    Task { await place.retryMail() }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("search.mail.retry")
            }
            .searchSectionNote("search.mail.failed")
        case .empty:
            Text(SearchSectionWords.mailEmpty)
                .searchSectionNote("search.mail.empty")
        case .rows(let total, let truncated, let stale):
            if stale {
                Text(SearchSectionWords.mailStale)
                    .searchSectionNote("search.mail.stale")
            }
            ForEach(SearchSections.mailHits(in: model)) { hit in
                SearchMailResultRow(envelope: hit.envelope, ref: hit.ref, actions: actions)
                    .tag(hit.id)
            }
            if let label = SearchSectionWords.showAllMail(total: total, truncated: truncated) {
                SearchShowAllRow(label: label, scope: .mail, place: place)
            }
        }
    }
}

/// The Feeds section's rows: under All the first matches and the row that
/// shows the rest, under Feeds every match with the next page asked for at
/// the end. Wherever feed results are listed, the line under them says
/// what they cover.
struct SearchFeedSectionRows: View {
    let status: FeedSectionStatus
    let model: MessageListViewModel
    let place: SearchPlace
    let actions: SearchRowActions

    var body: some View {
        switch status {
        case .idle:
            EmptyView()
        case .blocked(let filters):
            VStack(alignment: .leading, spacing: 6) {
                Text(SearchSectionWords.feedsBlocked(by: filters))
                Button("Clear those filters") {
                    model.search.filters = FeedSearchPlan.clearingMailOnly(model.search.filters)
                    Task { await place.submit() }
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("search.feeds.clearMailFilters")
            }
            .searchSectionNote("search.feeds.blocked")
        case .unreadable:
            Text(SearchSectionWords.feedsUnreadable)
                .searchSectionNote("search.feeds.unreadable")
        case .empty:
            Text(SearchSectionWords.feedsEmpty)
                .searchSectionNote("search.feeds.empty")
            coverage
        case .rows(let total):
            ForEach(Self.rows(of: place)) { item in
                SearchFeedResultRow(item: item, actions: actions)
                    .tag(item.ref)
            }
            if place.scope == .all {
                if let label = SearchSectionWords.showAllFeeds(total: total) {
                    SearchShowAllRow(label: label, scope: .feeds, place: place)
                }
            } else if place.feeds.hasMore {
                // Reaching the end of the loaded articles asks for more.
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
                    .onAppear {
                        Task { await place.feeds.loadMore(in: place.feedStore) }
                    }
                    .accessibilityIdentifier("search.feeds.loadingMore")
            }
            coverage
        }
    }

    /// The articles the section lists: the first few under All, every one
    /// loaded under Feeds.
    static func rows(of place: SearchPlace) -> [RssItem] {
        place.scope == .all ? Array(place.feeds.rows.prefix(SearchSectionWords.digestLimit)) : place.feeds.rows
    }

    private var coverage: some View {
        Text(SearchSectionWords.feedCoverage)
            .searchSectionNote("search.feeds.coverage")
    }
}

/// The row under a section's first matches: the control moves to that
/// medium, where every match is listed.
struct SearchShowAllRow: View {
    let label: String
    let scope: SearchScope
    let place: SearchPlace

    var body: some View {
        Button(label) {
            Task { await place.pick(scope) }
        }
        .buttonStyle(.borderless)
        .appFont(.footnote)
        .accessibilityIdentifier("search.showAll.\(scope.rawValue)")
    }
}

/// The row above a search's sectioned results: Filters, and the way out of
/// a search that has no term in the field to clear. It owns the filter
/// sheet, as the mail list owns its own.
struct SearchResultsControls: View {
    let model: MessageListViewModel
    let place: SearchPlace
    /// Ends the search, as the field's own clear does.
    let end: () -> Void
    @State private var filtersPresented = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                filtersPresented = true
            } label: {
                Label("Filters", systemImage: icon)
                    .labelStyle(.iconOnly)
            }
            .accessibilityLabel(activeFilters == 0 ? "Filters" : "Filters, \(activeFilters) active")
            .accessibilityIdentifier("search.filters")
            Spacer()
            Button(action: end) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("search.clear")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .sheet(isPresented: $filtersPresented) {
            filtersSheet
                .windowShapedSheet()
        }
    }

    /// How many filters are in play for the scope: under Feeds the ones
    /// only a message can pass are not offered, so they are not counted.
    private var activeFilters: Int {
        Self.activeFilters(model.search.filters, scope: place.scope)
    }

    static func activeFilters(_ filters: MessageSearchFilters, scope: SearchScope) -> Int {
        scope == .feeds ? FeedSearchPlan.clearingMailOnly(filters).activeCount : filters.activeCount
    }

    private var icon: String {
        activeFilters > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    }

    /// The filter sheet. Under Feeds it offers the four filters that
    /// narrow an article; the rest keep whatever they hold.
    @ViewBuilder
    private var filtersSheet: some View {
        @Bindable var search = model.search
        SearchFiltersSheet(
            filters: $search.filters,
            currentFolderName: model.search.folder?.name ?? "",
            allowFolderScope: model.search.folder != nil,
            mailFilters: place.scope != .feeds,
            onApply: { snapshot in
                search.filters = snapshot
                filtersPresented = false
                Task { await place.submit() }
            },
            onCancel: { filtersPresented = false }
        )
    }
}

extension View {
    /// A line that stands in a section in place of rows, or under them.
    func searchSectionNote(_ identifier: String) -> some View {
        appFont(.footnote)
            .foregroundStyle(.secondary)
            .listRowSeparator(.hidden)
            .accessibilityIdentifier(identifier)
    }
}
