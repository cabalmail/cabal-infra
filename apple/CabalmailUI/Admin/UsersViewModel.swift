import Foundation
import Observation
import CabalmailKit

/// The slice of the client the Users view needs, narrowed so tests can fake
/// six methods instead of conforming to the whole `ApiClient`.
protocol UsersBackend: Sendable {
    func listUsers() async throws -> [PoolUser]
    func listDomainAccess() async throws -> [DomainAllowance]
    func confirm(_ username: String) async throws
    func setEnabled(_ username: String, enabled: Bool) async throws
    func delete(_ username: String) async throws
    func setDomainAccess(user: String, domain: String, allowed: Bool) async throws
}

/// Production backend: the admin Lambdas (`CabalmailClient+Admin.swift`).
struct LiveUsersBackend: UsersBackend {
    let client: CabalmailClient

    func listUsers() async throws -> [PoolUser] { try await client.poolUsers() }
    func listDomainAccess() async throws -> [DomainAllowance] { try await client.domainAllowances() }
    func confirm(_ username: String) async throws { try await client.confirmUser(username) }

    func setEnabled(_ username: String, enabled: Bool) async throws {
        try await client.setUserEnabled(username, enabled: enabled)
    }

    func delete(_ username: String) async throws { try await client.deleteUser(username) }

    func setDomainAccess(user: String, domain: String, allowed: Bool) async throws {
        try await client.setDomainAccess(user: user, domain: domain, allowed: allowed)
    }
}

/// State for the administrator's Users view (auth parity plan, C2): the
/// pool's accounts, split into those awaiting confirmation and the rest, and
/// the per-user domain allow list.
///
/// Every action is admin only on the server. A 403 means this account is not
/// (or no longer) an administrator, whatever its token said: the view shows
/// that instead of the list, and `onAccessDenied` re-reads the session's
/// admin status so Settings stops listing Users.
@MainActor
@Observable
final class UsersViewModel {
    /// A failed action, for the view's alert.
    struct ActionError: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    /// Pool accounts the system itself signs in as: `master` (the Lambdas'
    /// IMAP logins), `dmarc` (report ingestion) and `ci-probe` (the
    /// post-deploy mail probe), the accounts `require_admin_mfa` exempts
    /// (`terraform/infra/modules/user_pool/require_admin_mfa.tf`). Hidden so
    /// none can be disabled or deleted by accident; the webmail hides the
    /// first two.
    static let systemUsernames: Set<String> = ["master", "dmarc", "ci-probe"]

    private let backend: UsersBackend
    private let onAccessDenied: @MainActor () async -> Void
    /// The configured mail domains, the ones access can be granted on.
    let domains: [String]
    /// The signed-in administrator, who can't disable or delete their own
    /// account here.
    let currentUsername: String

    private(set) var users: [PoolUser] = []
    private(set) var allowances: Set<DomainAllowance> = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    /// A load reached a definitive outcome. A cancellation mid-flight (the
    /// pushed destination rebuilt during a transition) leaves it false so
    /// the next `.task` loads again, as `RulesViewModel` does (#1328).
    private(set) var hasAttemptedLoad = false
    /// The server answered an admin call with 403.
    private(set) var accessDenied = false
    /// Usernames with an action on the wire; their buttons are disabled.
    private(set) var busy: Set<String> = []
    var actionError: ActionError?

    init(
        backend: UsersBackend,
        domains: [String],
        currentUsername: String,
        onAccessDenied: @escaping @MainActor () async -> Void = {}
    ) {
        self.backend = backend
        self.domains = domains
        self.currentUsername = currentUsername
        self.onAccessDenied = onAccessDenied
    }

    // MARK: - Reading

    /// Accounts awaiting confirmation: any Cognito status but `CONFIRMED`.
    var pending: [PoolUser] { listed.filter(\.isPending) }

    /// Confirmed accounts.
    var confirmed: [PoolUser] { listed.filter { !$0.isPending } }

    private var listed: [PoolUser] {
        users
            .filter { !Self.systemUsernames.contains($0.username) }
            .sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    func user(named username: String) -> PoolUser? {
        users.first { $0.username == username }
    }

    func isCurrentUser(_ username: String) -> Bool {
        username == currentUsername
    }

    func hasAccess(_ username: String, to domain: String) -> Bool {
        allowances.contains(DomainAllowance(user: username, domain: domain))
    }

    // MARK: - Loading

    /// Fetches the accounts and the allow list together; either failing fails
    /// the load, since toggles drawn from a missing allow list would all read
    /// as off.
    func load() async {
        isLoading = true
        loadError = nil
        do {
            async let fetchedUsers = backend.listUsers()
            async let fetchedAllowances = backend.listDomainAccess()
            let (loadedUsers, loadedAllowances) = try await (fetchedUsers, fetchedAllowances)
            users = loadedUsers
            allowances = Set(loadedAllowances)
            accessDenied = false
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            if Self.isForbidden(error) {
                await denyAccess()
            } else {
                loadError = "Couldn't load users: \(error.localizedDescription)"
            }
        }
        hasAttemptedLoad = true
        isLoading = false
    }

    // MARK: - Actions

    func confirm(_ username: String) async {
        await perform(on: username, failure: "Couldn't confirm \(username)") {
            try await self.backend.confirm(username)
            self.replace(username) { PoolUser(username: $0.username, status: "CONFIRMED", enabled: $0.enabled,
                                              created: $0.created, osid: $0.osid) }
        }
    }

    func setEnabled(_ username: String, enabled: Bool) async {
        guard enabled || !isCurrentUser(username) else { return }
        let verb = enabled ? "enable" : "disable"
        await perform(on: username, failure: "Couldn't \(verb) \(username)") {
            try await self.backend.setEnabled(username, enabled: enabled)
            self.replace(username) { PoolUser(username: $0.username, status: $0.status, enabled: enabled,
                                              created: $0.created, osid: $0.osid) }
        }
    }

    /// Deletes the account. True when it is gone, so a detail page can close.
    @discardableResult
    func delete(_ username: String) async -> Bool {
        guard !isCurrentUser(username) else { return false }
        var deleted = false
        await perform(on: username, failure: "Couldn't delete \(username)") {
            try await self.backend.delete(username)
            self.users.removeAll { $0.username == username }
            self.allowances = self.allowances.filter { $0.user != username }
            deleted = true
        }
        return deleted
    }

    /// Grants or revokes access to `domain`. The toggle moves at once and
    /// moves back if the server refuses.
    func setAccess(_ username: String, to domain: String, allowed: Bool) async {
        let allowance = DomainAllowance(user: username, domain: domain)
        let wasAllowed = allowances.contains(allowance)
        guard wasAllowed != allowed else { return }
        apply(allowance, allowed: allowed)
        let verb = allowed ? "grant" : "revoke"
        await perform(on: username, failure: "Couldn't \(verb) \(username)'s access to \(domain)") {
            try await self.backend.setDomainAccess(user: username, domain: domain, allowed: allowed)
        } onFailure: {
            self.apply(allowance, allowed: wasAllowed)
        }
    }

    // MARK: - Internals

    private func perform(
        on username: String,
        failure title: String,
        _ work: @MainActor () async throws -> Void,
        onFailure: @MainActor () -> Void = {}
    ) async {
        busy.insert(username)
        defer { busy.remove(username) }
        do {
            try await work()
        } catch {
            onFailure()
            if Self.isForbidden(error) {
                await denyAccess()
            } else {
                actionError = ActionError(title: title, message: error.localizedDescription)
            }
        }
    }

    private func replace(_ username: String, with transform: (PoolUser) -> PoolUser) {
        guard let index = users.firstIndex(where: { $0.username == username }) else { return }
        users[index] = transform(users[index])
    }

    private func apply(_ allowance: DomainAllowance, allowed: Bool) {
        if allowed {
            allowances.insert(allowance)
        } else {
            allowances.remove(allowance)
        }
    }

    private func denyAccess() async {
        accessDenied = true
        await onAccessDenied()
    }

    private static func isForbidden(_ error: Error) -> Bool {
        if case .http(status: 403, _) = error as? CabalmailError { return true }
        return false
    }
}
