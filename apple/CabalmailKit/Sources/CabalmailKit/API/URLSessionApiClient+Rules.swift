import Foundation

// MARK: - Mail rules

extension URLSessionApiClient {
    public func listRules() async throws -> RuleSet {
        let request = try await get("/get_rules")
        let data = try await send(request, expectedStatuses: 200..<300)
        return try JSONDecoder().decode(RuleSet.self, from: data)
    }

    public func setRules(_ rules: [Rule], expectedVersion: Int) async throws -> RuleSet {
        // Encode through JSONEncoder (the model owns its wire keys), then
        // bridge to the `[String: Any]` shape the shared `put` helper takes.
        let encodedRules = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rules))
        let request = try await put("/set_rules", json: [
            "rules": encodedRules,
            "expectedVersion": expectedVersion,
        ])
        do {
            let data = try await send(request, expectedStatuses: 200..<300)
            // The 200 body also carries `stripped` (invalid forward chips the
            // Lambda dropped) and `warnings` (folder targets accepted but
            // unverified until compile). Neither is surfaced: RulesValidator
            // flags bad forwards before the PUT, and the folder warning fires
            // for every folder target on every save, so it isn't actionable.
            return try JSONDecoder().decode(RuleSet.self, from: data)
        } catch CabalmailError.server(let code, let message) where code == "409" {
            throw RuleSetConflictError(serverVersion: Self.conflictVersion(message))
        }
    }

    /// The winning version out of a 409 body
    /// (`{"Error": "...", "version": N}`), or nil if the body didn't parse.
    private static func conflictVersion(_ body: String) -> Int? {
        struct Payload: Decodable { let version: Int? }
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.version
    }
}
