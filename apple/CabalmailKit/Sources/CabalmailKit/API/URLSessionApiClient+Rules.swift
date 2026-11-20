import Foundation

// MARK: - Mail rules

extension URLSessionApiClient {
    public func listRules() async throws -> RuleSet {
        let request = try await get("/get_rules")
        let data = try await send(request, expectedStatuses: 200..<300)
        return try decodeReply(RuleSet.self, from: data, for: request)
    }

    public func setRules(
        _ rules: [Rule], feedRules: [FeedRule]?, expectedVersion: Int
    ) async throws -> RuleSet {
        // Encode through JSONEncoder (the model owns its wire keys), then
        // bridge to the `[String: Any]` shape the shared `put` helper takes.
        var body: [String: Any] = [
            "rules": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rules)),
            "expectedVersion": expectedVersion,
        ]
        // The key is left off, not sent empty or null, when the caller has
        // no feed rules to write: the server reads a missing key as "leave
        // the stored list alone", an empty list as "clear it", and refuses
        // null.
        if let feedRules {
            body["feedRules"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(feedRules))
        }
        let request = try await put("/set_rules", json: body)
        do {
            let data = try await send(request, expectedStatuses: 200..<300)
            // The 200 body also carries `stripped` (invalid forward chips the
            // Lambda dropped) and `warnings` (folder targets accepted but
            // unverified until compile). Neither is surfaced: RulesValidator
            // flags bad forwards before the PUT, and the folder warning fires
            // for every folder target on every save, so it isn't actionable.
            return try decodeReply(RuleSet.self, from: data, for: request)
        } catch CabalmailError.http(409, let body) {
            throw RuleSetConflictError(serverVersion: Self.conflictVersion(body))
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
