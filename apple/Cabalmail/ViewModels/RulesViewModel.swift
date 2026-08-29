import Foundation
import Observation
import CabalmailKit

/// The slice of the client the rules editor needs, narrowed so tests can
/// fake four methods instead of conforming to the whole `ApiClient`.
protocol RulesBackend: Sendable {
    func fetchRules() async throws -> RuleSet
    func saveRules(_ rules: [Rule], expectedVersion: Int) async throws -> RuleSet
    func listFolders() async throws -> [Folder]
    func createFolder(name: String, parent: String?) async throws
}

/// Production backend: rules via the Lambda pair, folders via the same
/// IMAP surface the sidebar and the move sheet use.
struct LiveRulesBackend: RulesBackend {
    let client: CabalmailClient

    func fetchRules() async throws -> RuleSet {
        try await client.rules()
    }

    func saveRules(_ rules: [Rule], expectedVersion: Int) async throws -> RuleSet {
        try await client.saveRules(rules, expectedVersion: expectedVersion)
    }

    func listFolders() async throws -> [Folder] {
        try await client.imapClient.connectAndAuthenticate()
        return try await client.imapClient.listFolders()
    }

    func createFolder(name: String, parent: String?) async throws {
        try await client.imapClient.createFolder(name: name, parent: parent)
    }
}

/// State for the mail-rules editor (`docs/1.x/user-mail-rules-plan.md`,
/// Phase 4): the ordered rule array, the optimistic-concurrency version, and
/// the debounced whole-set auto-save.
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
    private(set) var rules: [Rule] = []
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
    }

    // MARK: - Loading

    /// Fetches the rule set (replacing all local state — also the conflict
    /// alert's Reload path) and refreshes the folder list best-effort.
    func load() async {
        isLoading = true
        loadError = nil
        do {
            let ruleSet = try await backend.fetchRules()
            // Legacy move/archive + continue renders and saves as the Copy
            // it compiles to (truthful Continue, decision 2). One-way; the
            // normalized form persists on the next edit's save.
            rules = ruleSet.rules.map { $0.normalizingLegacyContinue() }
            version = ruleSet.version
            saveState = .idle
            pendingSave = false
        } catch {
            // A cancellation raised by our own Task is SwiftUI tearing the
            // view's `.task` down mid-transition, not a server or network
            // failure: painting it would tell the user the rules couldn't be
            // reached when nothing was ever asked of the server. Stay in the
            // loading state with the attempt unrecorded so the re-created
            // view's `.task` retries (#1328). `URLSessionHTTPTransport`
            // normalizes the escaping error to `CabalmailError.network`, so
            // the cancellation is read off the Task, not off the error.
            if Task.isCancelled || error is CancellationError {
                return
            }
            loadError = "Couldn't load rules: \(error.localizedDescription)"
        }
        hasAttemptedLoad = true
        isLoading = false
        await refreshFolders()
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
        rules.first { $0.id == id }
    }

    func update(_ rule: Rule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }),
              rules[index] != rule
        else { return }
        rules[index] = rule
        scheduleSave()
    }

    /// Appends and returns the new rule's id so the caller can navigate to
    /// the editor. Returns nil at the server's rule-count cap.
    @discardableResult
    func add(_ rule: Rule = Rule(name: "New rule")) -> String? {
        guard rules.count < RulesValidator.maxRules else { return nil }
        rules.append(rule)
        scheduleSave()
        return rule.id
    }

    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard let original = rule(withID: id),
              let index = rules.firstIndex(where: { $0.id == id }),
              rules.count < RulesValidator.maxRules
        else { return nil }
        var copy = original
        copy.id = Rule.mintID()
        copy.name = original.name + " copy"
        rules.insert(copy, at: index + 1)
        scheduleSave()
        return copy.id
    }

    func delete(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        scheduleSave()
    }

    func delete(id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules.remove(at: index)
        scheduleSave()
    }

    func move(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        scheduleSave()
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard var rule = rule(withID: id) else { return }
        rule.enabled = enabled
        update(rule)
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
        // A set the validator rejects is a set the server 400s (or strips);
        // hold the PUT and surface the first problem instead. The next
        // mutation reschedules, so fixing the field resumes saving.
        if let issue = RulesValidator.validate(rules).first {
            saveState = .error(issue.message)
            return
        }
        saveInFlight = true
        saveState = .saving
        let snapshot = rules
        do {
            let saved = try await backend.saveRules(snapshot, expectedVersion: version)
            version = saved.version
            // Adopt the server-canonical set (ids it re-minted, forwards it
            // stripped) only if nothing changed locally mid-flight; edits
            // during the PUT have already scheduled their own save.
            if rules == snapshot {
                rules = saved.rules.map { $0.normalizingLegacyContinue() }
            }
            saveState = .saved
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
}
