import Foundation

/// In-memory cache for the user's address list.
///
/// Mirrors the React app's `localStorage[ADDRESS_LIST]` pattern
/// (`react/admin/src/ApiClient.js`): the list is fetched once per session
/// and invalidated on any mutation (`newAddress` / `revokeAddress`).
public actor AddressCache {
    private var addresses: [Address]?

    public init() {}

    public func get() -> [Address]? { addresses }

    public func set(_ addresses: [Address]) {
        self.addresses = addresses
    }

    public func invalidate() {
        addresses = nil
    }
}
