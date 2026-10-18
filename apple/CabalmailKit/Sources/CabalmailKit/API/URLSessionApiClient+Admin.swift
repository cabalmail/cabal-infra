import Foundation

// MARK: - Administration

extension URLSessionApiClient {
    public func listUsers() async throws -> [PoolUser] {
        let request = try await get("/list_users")
        let data = try await send(request, expectedStatuses: 200..<300)
        return try decodeReply(UsersReply.self, from: data, for: request).users
    }

    public func confirmUser(_ username: String) async throws {
        let request = try await put("/confirm_user", json: ["username": username])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func enableUser(_ username: String) async throws {
        let request = try await put("/enable_user", json: ["username": username])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func disableUser(_ username: String) async throws {
        let request = try await put("/disable_user", json: ["username": username])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func deleteUser(_ username: String) async throws {
        let request = try await delete("/delete_user", json: ["username": username])
        _ = try await send(request, expectedStatuses: 200..<300)
    }

    public func listUserDomainAccess() async throws -> [DomainAllowance] {
        let request = try await get("/list_user_domain_access")
        let data = try await send(request, expectedStatuses: 200..<300)
        return try decodeReply(AllowancesReply.self, from: data, for: request).allowances
    }

    public func setUserDomainAccess(user: String, domain: String, allowed: Bool) async throws {
        let request = try await put("/set_user_domain_access", json: [
            "user": user,
            "domain": domain,
            "allowed": allowed,
        ])
        _ = try await send(request, expectedStatuses: 200..<300)
    }
}

/// `/list_users` answers `{"Users": [...]}`.
private struct UsersReply: Decodable {
    let users: [PoolUser]
    private enum CodingKeys: String, CodingKey { case users = "Users" }
}

/// `/list_user_domain_access` answers `{"Allowances": [...]}`.
private struct AllowancesReply: Decodable {
    let allowances: [DomainAllowance]
    private enum CodingKeys: String, CodingKey { case allowances = "Allowances" }
}
