import Foundation
import Observation
import CabalmailKit

/// Backs `AddressListView` (the mailbox sidebar's address rail). Wraps
/// `CabalmailClient.addresses` and `revokeAddress` with list state, loading
/// indicators, and an error banner.
///
/// Mirrors the React app's `react/admin/src/Addresses/List.jsx` behavior:
/// one round-trip on open, a force-refresh on pull-to-refresh, and an
/// immediate in-place removal on revoke so the UI doesn't wait on the API
/// round-trip to hide the row.
@Observable
@MainActor
final class AddressesViewModel {
    var addresses: [Address] = []
    var isLoading = false
    var errorMessage: String?

    private let client: CabalmailClient

    init(client: CabalmailClient) {
        self.client = client
    }

    func refresh(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            addresses = try await client.addresses(forceRefresh: force)
                .sorted { $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke the given address via the API and prune it from the list. The
    /// local prune happens only after the call succeeds — a failed revoke
    /// (network, 4xx) leaves the list intact and surfaces an error banner.
    func revoke(_ address: Address) async {
        do {
            try await client.revokeAddress(
                address: address.address,
                subdomain: address.subdomain,
                tld: address.tld,
                publicKey: address.publicKey
            )
            addresses.removeAll { $0.id == address.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called after the inline "Create address" sheet reports success.
    /// Forces a fresh `/list` round-trip so the new address appears.
    func onAddressCreated() async {
        await refresh(force: true)
    }

    /// Addresses the caller has favorited. Same ordering as `addresses`.
    var favorites: [Address] {
        addresses.filter { $0.favorite }
    }

    /// Optimistically flip the favorite flag on `address`, fire the API call,
    /// and revert on failure. Mirrors the React rail's behavior.
    func toggleFavorite(_ address: Address) async {
        let target = !address.favorite
        applyFavorite(addressId: address.id, to: target)
        do {
            try await client.setFavorite(address: address.address, favorite: target)
            errorMessage = nil
        } catch {
            applyFavorite(addressId: address.id, to: !target)
            errorMessage = error.localizedDescription
        }
    }

    private func applyFavorite(addressId: String, to favorite: Bool) {
        guard let index = addresses.firstIndex(where: { $0.id == addressId }) else { return }
        addresses[index].favorite = favorite
    }

    /// Suspend or reinstate `address` via the API and flip the row's flag on
    /// success. Not optimistic (unlike favorites): the call withdraws or
    /// republishes DNS records server-side, so the row only changes state
    /// once the server confirms.
    func setSuspended(_ address: Address, to suspended: Bool) async {
        do {
            if suspended {
                try await client.suspendAddress(address: address.address)
            } else {
                try await client.reinstateAddress(address: address.address)
            }
            if let index = addresses.firstIndex(where: { $0.id == address.id }) {
                addresses[index].suspended = suspended
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
