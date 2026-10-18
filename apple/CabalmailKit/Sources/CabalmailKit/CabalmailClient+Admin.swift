import Foundation

/// Administration flows, following the same thin-facade pattern as
/// `CabalmailClient+Rules.swift`: views call the client, not the raw
/// `ApiClient`. Every call here is admin only on the server, which answers
/// anyone else with 403 whatever `isAdmin()` said.
extension CabalmailClient {
    /// Whether the signed-in user is an administrator, as the current ID
    /// token says. A hint for what to show (`AuthService.isAdmin()`).
    public func isAdmin() async -> Bool {
        await authService.isAdmin()
    }

    /// Every user in the pool.
    public func poolUsers() async throws -> [PoolUser] {
        try await apiClient.listUsers()
    }

    public func confirmUser(_ username: String) async throws {
        try await apiClient.confirmUser(username)
    }

    /// Enables or disables a user's sign-in.
    public func setUserEnabled(_ username: String, enabled: Bool) async throws {
        if enabled {
            try await apiClient.enableUser(username)
        } else {
            try await apiClient.disableUser(username)
        }
    }

    public func deleteUser(_ username: String) async throws {
        try await apiClient.deleteUser(username)
    }

    /// The whole domain allow list.
    public func domainAllowances() async throws -> [DomainAllowance] {
        try await apiClient.listUserDomainAccess()
    }

    public func setDomainAccess(user: String, domain: String, allowed: Bool) async throws {
        try await apiClient.setUserDomainAccess(user: user, domain: domain, allowed: allowed)
    }
}
