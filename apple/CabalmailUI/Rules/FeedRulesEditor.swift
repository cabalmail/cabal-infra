import Foundation
import Observation
import CabalmailKit

/// The feed half of the Rules pane: the user's feed rules, the edits the
/// "Feed items" section makes to them, and the subscriptions its Feed
/// picker offers.
///
/// It owns no saving. Mail rules and feed rules are one row on the server
/// under one version, so `RulesViewModel` saves both in one request and
/// owns the debounce, the conflict alert and the status bar; an edit here
/// only tells it something changed (`onChange`).
///
/// What it does own is the question of whether the feed list goes on that
/// request at all. `/set_rules` reads a request with no `feedRules` key as
/// "leave the stored list alone", which is what every build from before
/// feed rules sends. This build sends the same when the feed list is as
/// the server last gave it (`hasUnsavedChanges` false), so an edit to the
/// mail rules can never rewrite a feed rule, including one this build
/// decoded without everything a newer build wrote into it.
@MainActor
@Observable
final class FeedRulesEditor {
    private var list = RuleList<FeedRule>(maxCount: FeedRulesValidator.maxRules)
    /// The feed rules as the server last answered them: what the row holds.
    private var serverRules: [FeedRule] = []
    /// The user's subscriptions, by title, for the Feed picker and the
    /// rows' summaries. Best effort: empty until the device's feed list has
    /// loaded, and the views then show a rule's feed without its name.
    private(set) var subscriptions: [RssSubscription] = []
    /// Called after every edit that changed the list.
    @ObservationIgnored var onChange: () -> Void = {}

    var rules: [FeedRule] { list.rules }
    var isFull: Bool { list.isFull }

    /// Whether the list differs from what the server holds, so the next
    /// save has to carry it.
    var hasUnsavedChanges: Bool { list.rules != serverRules }

    // MARK: - The server's side

    /// A load: the server's list replaces the local one, edits and all.
    func load(_ rules: [FeedRule]) {
        serverRules = rules
        list.replace(with: rules)
    }

    /// The answer to a save that was sent while the list read `snapshot`.
    /// The server's list is what the row now holds either way; it replaces
    /// the local one only if nothing was edited mid-flight, the guard the
    /// mail rules use. An edit made during the PUT has scheduled a save of
    /// its own, and stays unsaved against the new baseline.
    func adopt(saved rules: [FeedRule], sentAs snapshot: [FeedRule]) {
        serverRules = rules
        if list.rules == snapshot {
            list.replace(with: rules)
        }
    }

    func setSubscriptions(_ subscriptions: [RssSubscription]) {
        self.subscriptions = subscriptions.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }

    /// The title of the subscription a rule is limited to, or nil when the
    /// id is not among the subscriptions this device knows.
    func subscriptionTitle(for id: String) -> String? {
        subscriptions.first { $0.subscriptionId == id }?.displayTitle
    }

    // MARK: - Edits

    func rule(withID id: String) -> FeedRule? {
        list.rule(withID: id)
    }

    func update(_ rule: FeedRule) {
        if list.update(rule) { onChange() }
    }

    /// Appends and returns the new rule's id so the caller can push its
    /// editor. Returns nil at the server's cap.
    ///
    /// A blank rule arrives disabled, as a blank mail rule does (#2031):
    /// with no conditions it matches every new item in every feed, and it
    /// is saved within a debounce of being added.
    @discardableResult
    func add(_ rule: FeedRule = FeedRule(name: "New rule", enabled: false)) -> String? {
        guard let id = list.add(rule) else { return nil }
        onChange()
        return id
    }

    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let copy = list.duplicate(id, mintID: Rule.mintID) else { return nil }
        onChange()
        return copy
    }

    func delete(at offsets: IndexSet) {
        list.delete(at: offsets)
        onChange()
    }

    func delete(id: String) {
        if list.delete(id: id) { onChange() }
    }

    /// Order means nothing to the fetcher (every matching rule applies);
    /// it is how the list is shown, and it is stored, so a reorder saves.
    func move(from source: IndexSet, to destination: Int) {
        list.move(from: source, to: destination)
        onChange()
    }

    func move(id: String, by offset: Int) {
        if list.move(id: id, by: offset) { onChange() }
    }

    func canMove(id: String, by offset: Int) -> Bool {
        list.canMove(id: id, by: offset)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if list.setEnabled(id, enabled) { onChange() }
    }
}
