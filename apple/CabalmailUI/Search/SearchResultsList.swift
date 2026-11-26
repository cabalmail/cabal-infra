import SwiftUI
import CabalmailKit

/// A search's results under All and under Feeds
/// (`docs/1.x/cross-media-ux-plan.md`, Phase 5): a section for each medium
/// in scope. Under All each section is its first matches and a row that
/// moves the control to its medium; under Feeds the one section is every
/// matching article, paged from the device. Under Mail the results are the
/// message list itself (`SearchResultsView`).
///
/// The media are sectioned, never merged: mail is searched on the server,
/// across the whole mailbox, and feeds on the device, across what it has
/// downloaded, and one merged list would claim a completeness the feed
/// half cannot.
struct SearchResultsList: View {
    let model: MessageListViewModel
    let place: SearchPlace
    /// The message the reader shows.
    @Binding var selection: Envelope?
    /// The article the reader shows.
    @Binding var article: RssItem?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    /// The bar's trailing items lead in book pose (`\.listBarItemsLead`).
    @Environment(\.listBarItemsLead) private var listBarItemsLead
    /// Aims this list's compose requests at its own window.
    @Environment(\.commandWindowID) private var commandWindowID

    var body: some View {
        let sections = SearchSections(model: model, place: place, isOffline: isOffline)
        Group {
            if place.submitted == nil {
                unsubmitted
            } else if sections.nothingMatched {
                nothingMatched
            } else {
                list(sections)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) {
            if place.submitted != nil {
                SearchResultsControls(model: model, place: place, end: endSearch)
            }
        }
        .navigationTitle("Search")
        .toolbar {
            // New Message keeps the slot the mail and feed lists give it,
            // so the primary action never moves between them.
            ToolbarItem(placement: .listBar(.primaryAction, leads: listBarItemsLead)) { composeButton }
                .keepsInBar()
        }
        .task {
            // The feed half follows the store for as long as it is listed.
            await place.feeds.observe(in: place.feedStore)
        }
        .task {
            // A mail half that failed offline answers once the connection
            // is back, with no tap.
            guard let reachability = appState.client?.reachability else { return }
            for await reachable in reachability.changes() where reachable {
                if case .failed = SearchSections(model: model, place: place, isOffline: false).mail {
                    await place.retryMail()
                }
            }
        }
    }

    private var isOffline: Bool { appState.client?.reachability?.isReachable == false }

    private var actions: SearchRowActions {
        SearchRowActions(model: model, place: place, preferences: preferences)
    }

    // MARK: The list

    private func list(_ sections: SearchSections) -> some View {
        List(selection: refSelection) {
            if place.scope == .all {
                Section {
                    SearchMailSectionRows(status: sections.mail, model: model, place: place, actions: actions)
                } header: {
                    SearchSectionHeader(title: SearchSectionWords.mailTitle, count: sections.mailCount)
                }
            }
            Section {
                SearchFeedSectionRows(status: sections.feeds, model: model, place: place, actions: actions)
            } header: {
                SearchSectionHeader(title: SearchSectionWords.feedsTitle, count: sections.feedCount)
            }
        }
        .listStyle(.plain)
    }

    /// The list selects a row by its identity; the host holds what is open,
    /// a message or an article and never both.
    private var refSelection: Binding<ItemRef?> {
        Binding(
            get: { selection.map { .mail(model.rowRef(for: $0)) } ?? article?.ref },
            set: { ref in open(ref) }
        )
    }

    private func open(_ ref: ItemRef?) {
        switch ref {
        case .mail(let message)?:
            guard let hit = SearchSections.mailHits(in: model).first(where: { $0.ref == message }) else { return }
            article = nil
            selection = hit.envelope
        case .feed?:
            guard let item = place.feeds.rows.first(where: { $0.ref == ref }) else { return }
            selection = nil
            article = item
            Task { await actions.didOpen(item) }
        case nil:
            selection = nil
            article = nil
        }
    }

    // MARK: Around the list

    /// Before anything is submitted: a term typed and not yet sent says so,
    /// as the mail results do; a pristine field says nothing.
    @ViewBuilder
    private var unsubmitted: some View {
        if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            Color.clear
        } else {
            ContentUnavailableView(
                SearchResultsPlaceholder.pressReturn.title, systemImage: "magnifyingglass",
                description: Text(SearchResultsPlaceholder.pressReturn.message(for: model.searchQuery))
            )
        }
    }

    private var nothingMatched: some View {
        ContentUnavailableView(
            SearchResultsPlaceholder.noMatches.title, systemImage: "magnifyingglass",
            description: Text(
                SearchSectionWords.nothingMatched(place.submitted ?? "", scope: place.scope)
                    + " " + SearchSectionWords.feedCoverage
            )
        )
        .accessibilityIdentifier("search.nothingMatched")
    }

    /// Ends the search as the field's own clear does: the term goes, and
    /// with it both halves.
    private func endSearch() {
        selection = nil
        article = nil
        place.searchEnded()
        Task { await model.clearSearch() }
    }

    private var composeButton: some View {
        Button {
            appState.compose.open(seed: ReplyBuilder.newDraft(), from: commandWindowID)
        } label: {
            Label("New Message", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityIdentifier("search.compose")
    }
}

/// A section's title with how many matches it has.
private struct SearchSectionHeader: View {
    let title: String
    let count: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let count {
                Text(count)
                    .monospacedDigit()
                    .accessibilityLabel("\(count) matches")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.section.\(title.lowercased())")
    }
}

/// What a search's two sections show, read from the window's search model
/// and its search place: one value both the list and its tests ask.
@MainActor
struct SearchSections {
    let mail: MailSectionStatus
    let feeds: FeedSectionStatus
    let scope: SearchScope

    init(model: MessageListViewModel, place: SearchPlace, isOffline: Bool) {
        scope = place.scope
        mail = MailSectionStatus(
            isActive: model.isSearchActive, isLoading: model.isLoading, hasError: model.errorMessage != nil,
            isOffline: isOffline, rowCount: model.envelopes.count,
            total: model.search.matchTotal ?? model.search.totalEstimate, truncated: model.search.truncated
        )
        feeds = FeedSectionStatus(
            plan: place.feedPlan, loaded: place.feeds.loaded, failed: place.feeds.failed,
            rowCount: place.feeds.rows.count, total: place.feeds.total
        )
    }

    /// Whether every section in scope answered with nothing, so the screen
    /// says so once in place of an empty line in each.
    var nothingMatched: Bool {
        switch scope {
        case .all: return mail.isEmpty && feeds.isEmpty
        case .feeds: return feeds.isEmpty
        case .mail: return mail.isEmpty
        }
    }

    var mailCount: String? {
        guard case .rows(let total, let truncated, _) = mail else { return nil }
        return SearchSectionWords.count(total, truncated: truncated)
    }

    var feedCount: String? {
        guard case .rows(let total) = feeds else { return nil }
        return SearchSectionWords.count(total)
    }

    /// A message among the sectioned results, with the identity its row
    /// is selected by.
    struct MailHit: Identifiable {
        let envelope: Envelope
        let ref: MessageRef
        var id: ItemRef { .mail(ref) }
    }

    /// The Mail section's rows under All: the search's first matches.
    static func mailHits(in model: MessageListViewModel) -> [MailHit] {
        model.envelopes.prefix(SearchSectionWords.digestLimit).map {
            MailHit(envelope: $0, ref: model.rowRef(for: $0))
        }
    }
}
