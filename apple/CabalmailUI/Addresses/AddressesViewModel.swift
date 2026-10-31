import Foundation
import Observation
import CabalmailKit

/// Backs `AddressListView` (the mailbox sidebar's address rail). Wraps
/// `CabalmailClient.addresses` and `revokeAddress` with list state, loading
/// indicators, and an error banner.
///
/// Mirrors the React app's `react/admin/src/Addresses/Rail.jsx` behavior:
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
    /// Called once a change lands on the server, so the other address lists
    /// read it (`AppState.addressesChanged()`).
    private let changed: () -> Void

    /// A favorite still out: the flag the latest toggle of an address asked
    /// for, and that toggle's number.
    private struct PendingFavorite {
        let favorite: Bool
        let toggle: Int
    }

    /// The favorites still out, by address id. A refresh lays them over the
    /// list it reads, which the server may have sent before the call landed,
    /// and an older toggle landing late leaves a newer one's flag alone.
    private var pendingFavorites: [String: PendingFavorite] = [:]
    private var favoriteToggles = 0

    init(client: CabalmailClient, changed: @escaping () -> Void = {}) {
        self.client = client
        self.changed = changed
    }

    func refresh(force: Bool = false) async {
        isLoading = true
        defer { isLoading = false }
        do {
            addresses = try await client.addresses(forceRefresh: force)
                .sorted { $0.address.localizedCaseInsensitiveCompare($1.address) == .orderedAscending }
            for (addressId, pending) in pendingFavorites {
                applyFavorite(addressId: addressId, to: pending.favorite)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke the given address via the API and prune it from the list. The
    /// local prune happens only after the call succeeds — a failed revoke
    /// (network, 4xx) leaves the list intact and surfaces an error banner.
    ///
    /// Returns whether the revoke landed, so the caller can confirm it. The
    /// list's own revoke used to raise nothing at all, which made the same
    /// destructive action silent from the address list and confirmed from
    /// the reader's per-address menu (#1454). The failure path stays with
    /// `errorMessage`, so a caller that only wants the success confirmation
    /// can ignore the banner and read this.
    @discardableResult
    func revoke(_ address: Address) async -> Bool {
        do {
            try await client.revokeAddress(
                address: address.address,
                subdomain: address.subdomain,
                tld: address.tld,
                publicKey: address.publicKey
            )
            addresses.removeAll { $0.id == address.id }
            errorMessage = nil
            changed()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Called after the inline "Create address" sheet reports success.
    /// Forces a fresh `/list` round-trip so the new address appears. The
    /// sheet itself tells the other lists (`NewAddressSheet`).
    func onAddressCreated() async {
        await refresh(force: true)
    }

    /// Addresses the caller has favorited. Same ordering as `addresses`.
    var favorites: [Address] {
        addresses.filter { $0.favorite }
    }

    /// Optimistically flip the favorite flag on `address`, fire the API call,
    /// and revert on failure. Mirrors the React rail's behavior.
    ///
    /// Only the latest toggle of an address settles its row: a refresh while
    /// a call is out keeps the flag it asked for, and an older call landing
    /// after a newer toggle leaves the newer flag in place.
    func toggleFavorite(_ address: Address) async {
        let target = !address.favorite
        favoriteToggles += 1
        let toggle = favoriteToggles
        pendingFavorites[address.id] = PendingFavorite(favorite: target, toggle: toggle)
        applyFavorite(addressId: address.id, to: target)
        do {
            try await client.setFavorite(address: address.address, favorite: target)
            guard pendingFavorites[address.id]?.toggle == toggle else { return }
            pendingFavorites[address.id] = nil
            applyFavorite(addressId: address.id, to: target)
            errorMessage = nil
            changed()
        } catch {
            guard pendingFavorites[address.id]?.toggle == toggle else { return }
            pendingFavorites[address.id] = nil
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
            changed()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
