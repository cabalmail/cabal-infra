import Foundation
import Observation
import CabalmailKit

/// The slice of the client the rules editor needs, narrowed so tests can
/// fake five methods instead of conforming to the whole `ApiClient`.
protocol RulesBackend: Sendable {
    func fetchRules() async throws -> RuleSet
    /// Saves the mail rules and, when `feedRules` is not nil, the feed
    /// rules with them. Nil leaves the stored feed rules as they are.
    func saveRules(
        _ rules: [Rule], feedRules: [FeedRule]?, expectedVersion: Int
    ) async throws -> RuleSet
    func listFolders() async throws -> [Folder]
    func createFolder(name: String, parent: String?) async throws
    /// The user's feed subscriptions, for a feed rule's Feed picker.
    func listSubscriptions() async throws -> [RssSubscription]
}

/// Production backend: rules via the Lambda pair, folders via the same
/// IMAP surface the sidebar and the move sheet use, subscriptions from the
/// feed store the Feeds sidebar reads.
struct LiveRulesBackend: RulesBackend {
    let client: CabalmailClient

    func fetchRules() async throws -> RuleSet {
        try await client.rules()
    }

    func saveRules(
        _ rules: [Rule], feedRules: [FeedRule]?, expectedVersion: Int
    ) async throws -> RuleSet {
        try await client.saveRules(rules, feedRules: feedRules, expectedVersion: expectedVersion)
    }

    /// The device's synced copy, as the Feeds sidebar shows it, rather than
    /// a request of its own: the picker should offer the feeds the user
    /// sees. Empty on a bare client, which has no feed store.
    func listSubscriptions() async throws -> [RssSubscription] {
        try await client.rssStore?.subscriptions() ?? []
    }

    func listFolders() async throws -> [Folder] {
        try await client.imapClient.listFolders()
    }

    func createFolder(name: String, parent: String?) async throws {
        try await client.imapClient.createFolder(name: name, parent: parent)
    }
}

/// State for the rules editor (`docs/1.x/user-mail-rules-plan.md`,
/// Phase 4): the ordered mail rule array, the optimistic-concurrency version,
/// and the debounced whole-set auto-save. The feed rules, which the server
/// keeps beside the mail rules under the same version, are `feed`'s; this
/// model saves both lists in one request.
///
/// Every mutation goes through `update` / `add` / `delete` / `move`, which
/// splice the local array and schedule one debounced PUT of the entire set —
/// array order is precedence server-side, so there is no per-rule save.
/// A save that loses the version race flips `conflict`; the alert's only
/// affordance is Reload, matching the web plan (no merge UI in v1).
@MainActor
@Observable
final class RulesViewModel {
    enum SaveState: Equatable {
        case idle, saving, saved
        case error(String)
    }

    private let backend: RulesBackend
    private var mail = RuleList<Rule>(maxCount: RulesValidator.maxRules)
    /// The mail rules, in precedence order.
    var rules: [Rule] { mail.rules }
    /// The feed rules and their edits. Its changes save through this model.
    let feed = FeedRulesEditor()
    private(set) var version = 0
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// A load attempt reached a definitive outcome (loaded, or failed for a
    /// reason worth showing). A mid-flight cooperative cancellation leaves
    /// this false so the next live `.task` takes the load over — the rule
    /// `MessageDetailViewModel.load` already follows for the body fetch
    /// (#403), applied here for #1328.
    private(set) var hasAttemptedLoad = false
    private(set) var saveState: SaveState = .idle
    /// Another device saved first (409). Bound to the reload alert.
    var conflict = false
    /// The user's existing folders (selectable only — no create affordance in
    /// the pickers; see the plan's "No folder auto-creation").
    private(set) var folders: [Folder] = []

    /// Debounce for the auto-save PUT; tests shrink it.
    var saveDebounce: Duration = .milliseconds(300)

    private var debounceTask: Task<Void, Never>?
    private var saveInFlight = false
    private var pendingSave = false

    init(backend: RulesBackend) {
        self.backend = backend
        feed.onChange = { [weak self] in self?.scheduleSave() }
    }

    // MARK: - Loading

    /// Fetches both rule lists (replacing all local state — also the
    /// conflict alert's Reload path) and refreshes the folder list and the
    /// subscriptions best-effort.
    func load() async {
        isLoading = true
        loadError = nil
        do {
            let ruleSet = try await backend.fetchRules()
            // Legacy move/archive + continue renders and saves as the Copy
            // it compiles to (truthful Continue, decision 2). One-way; the
            // normalized form persists on the next edit's save.
            mail.replace(with: ruleSet.rules.map { $0.normalizingLegacyContinue() })
            feed.load(ruleSet.feedRules)
            version = ruleSet.version
            saveState = .idle
            pendingSave = false
        } catch {
            // A cancellation raised by our own Task is SwiftUI tearing the
            // view's `.task` down mid-transition, not a server or network
            // failure: painting it would tell the user the rules couldn't be
            // reached when nothing was ever asked of the server. Stay in the
            // loading state with the attempt unrecorded so the re-created
            // view's `.task` retries (#1328). The cancellation is read off
            // the Task, not off the error: `URLSessionHTTPTransport` reports
            // it as `CabalmailError.cancelled` (#1815), and as `.network`
            // before that.
            if Task.isCancelled || error is CancellationError {
                return
            }
            loadError = "Couldn't load rules: \(error.localizedDescription)"
        }
        hasAttemptedLoad = true
        isLoading = false
        await refreshFolders()
        await refreshSubscriptions()
    }

    /// Subscriptions for a feed rule's Feed picker. Best-effort, as the
    /// folder list is: a failure leaves the picker with "All feeds" alone.
    func refreshSubscriptions() async {
        guard let all = try? await backend.listSubscriptions() else { return }
        feed.setSubscriptions(all)
    }

    /// Folder list for the destination pickers: existing folders minus
    /// `\Noselect` containers, in the shared sidebar order. Best-effort — a
    /// failure leaves the pickers empty but the editor usable.
    func refreshFolders() async {
        guard let all = try? await backend.listFolders() else { return }
        folders = FolderTree.sidebarOrder(
            all.filter { !$0.attributes.contains("\\Noselect") }
        )
    }

    var hasArchiveFolder: Bool {
        folders.contains { $0.path == "Archive" }
    }

    /// The one sanctioned folder creation: the user explicitly asked for an
    /// Archive folder from the Archive action's inline prompt.
    func createArchiveFolder() async -> Bool {
        do {
            try await backend.createFolder(name: "Archive", parent: nil)
            await refreshFolders()
            return hasArchiveFolder
        } catch {
            return false
        }
    }

    // MARK: - Mutations

    func rule(withID id: String) -> Rule? {
        mail.rule(withID: id)
    }

    /// Writes an edited rule back. A rule the editors render read-only
    /// (`Rule.isEditable` false — a field or action newer than this build)
    /// is refused here rather than only in the views: saving a rewritten
    /// copy of a rule we can't represent would drop whatever the newer
    /// writer meant (#1901).
    func update(_ rule: Rule) {
        if mail.update(rule) { scheduleSave() }
    }

    /// Appends and returns the new rule's id so the caller can navigate to
    /// the editor. Returns nil at the server's rule-count cap.
    ///
    /// A blank rule arrives DISABLED, as every template does: it has no
    /// conditions, so it matches every message, and it is saved to the
    /// server within a debounce of being added. Enabled, it is a live
    /// every-message rule the user never switched on, shadowing everything
    /// below it the moment it is dragged up (#2031).
    @discardableResult
    func add(_ rule: Rule = Rule(name: "New rule", enabled: false)) -> String? {
        guard let id = mail.add(rule) else { return nil }
        scheduleSave()
        return id
    }

    /// Nil for a rule this build can't render: its copy would be a new rule
    /// this build can't express, and the row hides Duplicate for one.
    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let copy = mail.duplicate(id, mintID: Rule.mintID) else { return nil }
        scheduleSave()
        return copy
    }

    func delete(at offsets: IndexSet) {
        mail.delete(at: offsets)
        scheduleSave()
    }

    func delete(id: String) {
        if mail.delete(id: id) { scheduleSave() }
    }

    func move(from source: IndexSet, to destination: Int) {
        mail.move(from: source, to: destination)
        scheduleSave()
    }

    /// Moves one rule `offset` places: -1 is Move Up and +1 Move Down, the
    /// row menus' route to reordering and the only one on the Mac, whose
    /// grouped Settings form ignores `onMove`. Addressed by id, like the
    /// row's other actions. Past either end, or for a rule that is gone,
    /// nothing moves and nothing is saved.
    func move(id: String, by offset: Int) {
        if mail.move(id: id, by: offset) { scheduleSave() }
    }

    /// Whether `move(id:by:)` would move the rule, for the menus' enabling.
    func canMove(id: String, by offset: Int) -> Bool {
        mail.canMove(id: id, by: offset)
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if mail.setEnabled(id, enabled) { scheduleSave() }
    }

    // MARK: - Saving

    /// Immediate retry for the error state's Retry affordance.
    func retrySave() {
        debounceTask?.cancel()
        Task { await performSave() }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: saveDebounce)
            guard !Task.isCancelled else { return }
            // The PUT runs in its own task: cancelling the debounce (the
            // next keystroke) must never abort an in-flight request. The
            // server commits a PUT whether or not the client hangs up, so
            // an aborted request leaves `version` stale and the next save
            // misreads its 409 as another device's edit.
            Task { await performSave() }
        }
    }

    private func performSave() async {
        if saveInFlight {
            pendingSave = true
            return
        }
        // The feed list rides this request only when it differs from what
        // the server holds. Left off, the server keeps its list, so an edit
        // to the mail rules sends what a build from before feed rules sends
        // and cannot rewrite a feed rule (see `FeedRulesEditor`).
        let feedSnapshot = feed.rules
        let feedToSend = feed.hasUnsavedChanges ? feedSnapshot : nil
        // A set the validator rejects is a set the server 400s (or strips);
        // hold the PUT and surface the first problem instead. The next
        // mutation reschedules, so fixing the field resumes saving. A feed
        // list that is not being sent is the server's own and is not judged:
        // it must not hold a mail save.
        let issues = RulesValidator.validate(rules)
            + (feedToSend.map(FeedRulesValidator.validate) ?? [])
        if let issue = issues.first {
            saveState = .error(issue.message)
            return
        }
        saveInFlight = true
        saveState = .saving
        let snapshot = rules
        do {
            let saved = try await backend.saveRules(
                snapshot, feedRules: feedToSend, expectedVersion: version
            )
            adopt(saved, sentAs: snapshot, feedSentAs: feedSnapshot)
            saveState = .saved
        } catch CabalmailError.decoding {
            // `/set_rules` commits before it answers, so a 200 whose body
            // won't decode is a save that landed with its reply lost.
            // Reporting it as a failed save left `version` behind the
            // server's, and the next save's 409 then told the user another
            // device had edited their rules (#1903). Re-read instead.
            await resyncAfterUnreadableSave(snapshot, feedSnapshot)
        } catch is RuleSetConflictError {
            conflict = true
            saveState = .idle
        } catch {
            saveState = .error(error.localizedDescription)
        }
        saveInFlight = false
        if pendingSave {
            pendingSave = false
            scheduleSave()
        }
    }

    /// Takes the server's answer to a save sent while the lists read
    /// `snapshot` and `feedSnapshot`: its version is the one the next save
    /// has to quote, and its canonical lists (ids it re-minted, forwards it
    /// stripped, the feed rules the row now holds) replace the local ones,
    /// each only if nothing changed in it mid-flight; edits during the PUT
    /// have already scheduled their own save.
    ///
    /// And only if the server's list differs from the local one. Nearly
    /// every answer is the list as it was sent, and replacing the rules
    /// with an equal copy is not free: a decoded condition has a new local
    /// `id`, so the editor's condition rows would be rebuilt and the field
    /// being typed in would lose the keyboard each time a save landed.
    private func adopt(_ saved: RuleSet, sentAs snapshot: [Rule], feedSentAs feedSnapshot: [FeedRule]) {
        version = saved.version
        let canonical = saved.rules.map { $0.normalizingLegacyContinue() }
        if rules == snapshot, canonical != snapshot {
            mail.replace(with: canonical)
        }
        feed.adopt(saved: saved.feedRules, sentAs: feedSnapshot)
    }

    /// Re-reads the set after a save whose reply was unreadable. The PUT
    /// committed, so the server's version is the one the next save has to
    /// quote, and its canonical lists are the ones to show, under the same
    /// mid-flight guard the readable path uses. A re-read that fails leaves
    /// the save in the error state it would have had, with `version` stale:
    /// the next save's 409 is then a real race the Reload alert resolves.
    private func resyncAfterUnreadableSave(_ snapshot: [Rule], _ feedSnapshot: [FeedRule]) async {
        do {
            adopt(try await backend.fetchRules(), sentAs: snapshot, feedSentAs: feedSnapshot)
            saveState = .saved
        } catch {
            saveState = .error(error.localizedDescription)
        }
    }
}
