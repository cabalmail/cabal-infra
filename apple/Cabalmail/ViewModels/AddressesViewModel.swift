import Foundation
import Observation
import CabalmailKit

/// Backs `AddressesView`. Wraps `CabalmailClient.addresses` and
/// `revokeAddress` with list state, loading indicators, and an error banner.
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
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
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
        } catch let error as CabalmailError {
            errorMessage = String(describing: error)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Called after the inline "Create address" sheet reports success.
    /// Forces a fresh `/list` round-trip so the new address appears.
    func onAddressCreated() async {
        await refresh(force: true)
    }
}
