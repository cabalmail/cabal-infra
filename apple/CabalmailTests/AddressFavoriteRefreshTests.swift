import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A favorite that lands keeps its star when the list re-read the client's
/// cache while the call was out: `AddressListView` refreshes its model each
/// time it comes back on screen (the inspector keeps the view while closed,
/// and the laptop panel's address list may have changed an address
/// meanwhile, #1649), and the cache is cleared only once the call returns.
@MainActor
final class AddressFavoriteRefreshTests: XCTestCase {
    private static let target = Address(address: "pick@a.example", subdomain: "a", tld: "example")

    func testAFavoriteThatLandsSurvivesARefreshWhileItWasOut() async throws {
        let holder = ModelHolder()
        // The refresh's cached list, with the old flag, landing mid-call.
        let model = try makeModel(status: 200) { await holder.revert() }
        holder.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(model.addresses.first?.favorite, true)
        XCTAssertNil(model.errorMessage)
    }

    func testAFavoriteThatFailsStillComesBack() async throws {
        let holder = ModelHolder()
        let model = try makeModel(status: 500) { await holder.revert() }
        holder.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(model.addresses.first?.favorite, false)
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - Fixtures

    private func makeModel(
        status: Int, whileOut: @escaping @Sendable () async -> Void
    ) throws -> AddressesViewModel {
        let client = try TestFixtures.makeClient(
            imap: FakeImapClient(), transport: HookedStatusTransport(status: status, whileOut: whileOut)
        )
        let model = AddressesViewModel(client: client)
        model.addresses = [Self.target]
        return model
    }
}

/// Stands in for a refresh that read the cache from before the call.
@MainActor
private final class ModelHolder {
    var model: AddressesViewModel?

    func revert() {
        guard let model, !model.addresses.isEmpty else { return }
        model.addresses[0].favorite = false
    }
}

/// Answers every request with one status, running `whileOut` first, while
/// the caller is still waiting on the answer.
private struct HookedStatusTransport: HTTPTransport {
    let status: Int
    let whileOut: @Sendable () async -> Void

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await whileOut()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
}
