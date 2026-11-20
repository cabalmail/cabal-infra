import Foundation

/// Mail-rules flows, following the same thin-facade pattern as the
/// preference methods in `CabalmailClient+Addresses.swift`: views call the
/// client, not the raw `ApiClient`, so the app layer has one integration
/// surface.
extension CabalmailClient {
    /// The signed-in user's mail rules (ordered) and feed rules. No local
    /// cache — the set is one small row, the editor is the only consumer,
    /// and a consistent server read is what makes the 409-then-reload flow
    /// trustworthy.
    public func rules() async throws -> RuleSet {
        try await apiClient.listRules()
    }

    /// Replaces the whole mail rule list (array order is precedence) and,
    /// when `feedRules` is given, the whole feed rule list with it. A nil
    /// `feedRules` leaves the stored feed rules as they are. Throws
    /// `RuleSetConflictError` when another device saved first; the caller
    /// reloads via `rules()` and reapplies.
    @discardableResult
    public func saveRules(
        _ rules: [Rule], feedRules: [FeedRule]? = nil, expectedVersion: Int
    ) async throws -> RuleSet {
        try await apiClient.setRules(rules, feedRules: feedRules, expectedVersion: expectedVersion)
    }
}
