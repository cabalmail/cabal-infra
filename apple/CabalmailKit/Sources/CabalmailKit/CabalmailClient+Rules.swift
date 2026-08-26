import Foundation

/// Mail-rules flows, following the same thin-facade pattern as the
/// preference methods in `CabalmailClient+Addresses.swift`: views call the
/// client, not the raw `ApiClient`, so the app layer has one integration
/// surface.
extension CabalmailClient {
    /// The signed-in user's ordered rule set. No local cache — the set is
    /// one small row, the editor is the only consumer, and a consistent
    /// server read is what makes the 409-then-reload flow trustworthy.
    public func rules() async throws -> RuleSet {
        try await apiClient.listRules()
    }

    /// Replaces the whole rule set (array order is precedence). Throws
    /// `RuleSetConflictError` when another device saved first; the caller
    /// reloads via `rules()` and reapplies.
    @discardableResult
    public func saveRules(_ rules: [Rule], expectedVersion: Int) async throws -> RuleSet {
        try await apiClient.setRules(rules, expectedVersion: expectedVersion)
    }
}
