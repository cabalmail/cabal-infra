import SwiftUI
import CabalmailKit

/// A window's search results on every layout: the All / Mail / Feeds
/// control, and under it the results for the scope it is on
/// (flags-and-cross-media.md, decision 17).
///
/// Under Mail the results are the message list in search mode, exactly as
/// before the scope existed: its banner, its Filters, its selection, its
/// swipes and its paging. Under All and Feeds they are `SearchResultsList`.
/// The wide shells mount this in their list column while their search
/// field is engaged (`MailContentColumn`); the tab layouts' Search tab
/// mounts it under its own field (`SearchView`).
struct SearchResultsView: View {
    /// The window's search model (`SceneNavigator.searchModel`).
    let model: MessageListViewModel
    /// The message the reader shows.
    @Binding var selection: Envelope?
    /// The article the reader shows.
    @Binding var article: RssItem?
    /// How many messages the mail list has selected.
    let onSelectionCountChanged: (Int) -> Void

    @Environment(SceneNavigator.self) private var navigator

    var body: some View {
        let place = navigator.searchPlace
        VStack(spacing: 0) {
            SearchScopeBar(scope: place.scope) { picked in
                Task { await place.pick(picked) }
            }
            if place.scope == .mail {
                // Stable `.id` so the list isn't torn down per keystroke;
                // the reader opens each result against its true mailbox.
                MessageListView(
                    scope: .search,
                    injectedSearchModel: model,
                    selection: $selection,
                    onSelectionCountChanged: onSelectionCountChanged
                )
                .id("search")
            } else {
                SearchResultsList(model: model, place: place, selection: $selection, article: $article)
                    // The sectioned results have no multi-selection.
                    .onAppear { onSelectionCountChanged(0) }
            }
        }
        .modifier(SearchItemCommands(model: model, place: place, message: $selection, article: article))
        // The field was emptied (its own clear, Cancel, or the term
        // deleted): the search ends for both halves. The mail list ends
        // its own half while it is mounted; under All and Feeds it is not,
        // so the mail half is ended from here.
        .onChange(of: model.searchQuery) { _, query in
            guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let mailListIsUp = place.scope == .mail
            place.searchEnded()
            if !mailListIsUp, model.isSearchActive { Task { await model.clearSearch() } }
        }
        // The mail half began a search of its own (its filter sheet's
        // Apply, a pill), or was cleared with no term in the field to empty
        // (a search by filters alone, ended from its banner).
        .onChange(of: model.isSearchActive) { _, isActive in
            if isActive {
                place.mailSearchBegan()
            } else if model.searchQuery.isEmpty, place.submitted != nil, place.scope.includesMail {
                place.searchEnded()
            }
        }
    }
}
