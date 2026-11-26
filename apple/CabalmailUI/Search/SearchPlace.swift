import Foundation
import Observation
import CabalmailKit

/// A window's search across both media: the scope it is on, the term it
/// was last submitted with, the feed half's results, and on the wide
/// layouts the article open from them.
///
/// The mail half is the window's search model as it was
/// (`SceneNavigator.searchModel`, a message list in search mode), and this
/// stands beside it: the navigator holds one of each per window, so the
/// wide layouts' field, the Search tab and a change of layout shell all
/// read one search. Nothing here is written to the route or to disk; a
/// restored window opens with no search.
@Observable
@MainActor
final class SearchPlace {
    private(set) var scopeState = SearchScopeState()
    /// The term the search was last submitted with, trimmed; nil while
    /// nothing has been submitted. The mail half records its own
    /// (`MailSearchSession.submittedQuery`), but it does not run under
    /// Feeds, so this is the one both halves answer to.
    private(set) var submitted: String?
    /// The article open from the results on a wide layout, whose reader
    /// column shows it. The Search tab pushes its own.
    var openArticle: RssItem?
    let feeds = FeedSearchSession()

    /// The window's search model, attached when the navigator makes it.
    @ObservationIgnored private(set) weak var model: MessageListViewModel?
    /// The feed store and engine the feed half uses in place of the
    /// client's own: a test's.
    @ObservationIgnored var feedStoreOverride: FlaggedFeedStore?

    var scope: SearchScope { scopeState.scope }

    func attach(_ model: MessageListViewModel) {
        self.model = model
    }

    /// The device's feed store, and the engine a mark is written through.
    var feedStore: FlaggedFeedStore {
        feedStoreOverride ?? FlaggedFeedStore(store: model?.client.rssStore, engine: model?.client.rssSync)
    }

    /// Whether the window is in the middle of a search: a term typed, or
    /// one submitted, or the mail half showing results.
    var searchInProgress: Bool {
        submitted != nil || model.map { !$0.searchQuery.isEmpty || $0.isSearchActive } ?? false
    }

    /// What the feed half does with the search as submitted and the
    /// filters as they stand; nil before anything is submitted.
    var feedPlan: FeedSearchPlan? {
        guard let submitted, let model else { return nil }
        return FeedSearchPlan(text: submitted, filters: model.search.filters)
    }

    // MARK: The scope

    /// What is in front of the search, as the scope a search begun now
    /// opens on (`SearchFront`). One in progress keeps the scope it has.
    func noteFront(_ front: SearchScope) {
        scopeState.noteFront(front, searchInProgress: searchInProgress)
    }

    /// A pick of the control. A search already submitted is run for the
    /// medium the new scope adds, if that half does not hold it.
    func pick(_ scope: SearchScope) async {
        scopeState.pick(scope)
        guard submitted != nil else { return }
        if scope.includesMail, !mailIsCurrent {
            await submit()
        } else if scope.includesFeeds, !feedsAreCurrent {
            await runFeeds()
        }
    }

    // MARK: Running

    /// Runs the search in the field over the scope's media: the field's
    /// Return, and the filter sheet's Apply. With no term and no filter
    /// there is nothing to match on, and the search ends, as the mail half
    /// alone has always ended it.
    func submit() async {
        guard let model else { return }
        let text = model.searchQuery.trimmingCharacters(in: .whitespaces)
        if text.isEmpty, model.search.filters.hasNoPredicate {
            searchEnded()
            await model.clearSearch()
            return
        }
        submitted = text
        // The feed half first: it is on the device, so its rows are up
        // before the mail request has left.
        await runFeeds()
        if scope.includesMail { await model.runSearch() }
    }

    /// The mail half's last answer failed, and the connection is back or
    /// Retry was pressed: the submitted search again, for mail alone.
    func retryMail() async {
        guard let model, let submitted, scope.includesMail else { return }
        // The term the mail half was last sent with is the submitted one
        // unless it has never run it (the search began under Feeds).
        await model.runSearch(resetFilterTab: false, rerun: model.search.submittedQuery == submitted)
    }

    /// The search was cleared: the pick, the term, the feed half and the
    /// open article go. The mail half is cleared by whoever cleared the
    /// search (`MessageListViewModel.clearSearch`).
    func searchEnded() {
        scopeState.searchEnded()
        submitted = nil
        openArticle = nil
        feeds.clear()
    }

    /// The window is leaving a layout shell: the wide layout's open
    /// article is handed over for the next layout's search to take
    /// (`ShellHandOff`), and what was in front is forgotten.
    func leaveLayout() -> RssItem? {
        defer { openArticle = nil }
        scopeState.layoutChanged()
        return openArticle
    }

    // MARK: Each half's currency

    /// Whether the mail half has run the submitted term. A filter changed
    /// since is the mail list's own to re-run (its sheet's Apply).
    private var mailIsCurrent: Bool {
        guard let model, let submitted else { return false }
        return mailHasRun && model.search.submittedQuery == submitted
    }

    private var mailHasRun: Bool {
        guard let model else { return false }
        return model.isSearchActive || model.isLoading
    }

    private var feedsAreCurrent: Bool {
        feedPlan?.search == feeds.search
    }

    private func runFeeds() async {
        guard scope.includesFeeds, let search = feedPlan?.search else {
            // Blocked by a mail-only filter, or out of scope: no rows of an
            // earlier search stand in for this one's.
            feeds.clear()
            return
        }
        await feeds.run(search, in: feedStore)
    }
}
