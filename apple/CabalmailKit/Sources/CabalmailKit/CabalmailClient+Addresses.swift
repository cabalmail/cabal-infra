import Foundation

/// Address-management and preference flows split out of
/// `CabalmailClient.swift` so the actor's primary body stays under
/// SwiftLint's type_body_length cap. Same-module extension; everything here
/// runs on the actor as usual.
extension CabalmailClient {
    /// Returns the signed-in user's address list, consulting the in-memory
    /// cache first and invalidating on mutation. Views call this instead of
    /// the raw `ApiClient` to match the React app's implicit cache behavior.
    public func addresses(forceRefresh: Bool = false) async throws -> [Address] {
        if !forceRefresh, let cached = await addressCache.get() {
            return cached
        }
        let fresh = try await apiClient.listAddresses()
        await addressCache.set(fresh)
        return fresh
    }

    public func requestAddress(
        username: String,
        subdomain: String,
        tld: String,
        comment: String?,
        address: String
    ) async throws {
        try await apiClient.newAddress(
            username: username,
            subdomain: subdomain,
            tld: tld,
            comment: comment,
            address: address
        )
        await addressCache.invalidate()
    }

    public func revokeAddress(address: String, subdomain: String, tld: String, publicKey: String?) async throws {
        try await apiClient.revokeAddress(
            address: address,
            subdomain: subdomain,
            tld: tld,
            publicKey: publicKey
        )
        await addressCache.invalidate()
    }

    /// Toggles the caller's favorite flag on an address. Invalidates the
    /// address cache so the next `addresses(...)` call sees the new state.
    public func setFavorite(address: String, favorite: Bool) async throws {
        try await apiClient.setFavorite(address: address, favorite: favorite)
        await addressCache.invalidate()
    }

    /// Fetches the user's display-name preference. The `/send` Lambda uses
    /// it server-side as the From header's display name, so this value only
    /// drives the Settings field - outgoing mail picks it up with no client
    /// involvement. Empty string means unset.
    public func displayName() async throws -> String {
        try await apiClient.fetchDisplayName()
    }

    /// Persists the display-name preference server-side, where it is shared
    /// with the other clients (the React app edits the same row).
    public func setDisplayName(_ name: String) async throws {
        try await apiClient.updateDisplayName(name)
    }
}
