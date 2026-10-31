import XCTest
import CabalmailKit
@testable import CabalmailUI

/// A favorite against the list re-reading itself while the call is out:
/// `AddressListView` refreshes its model each time it comes back on screen,
/// and on every address change another list makes (the inspector and the
/// laptop panel's address list are two lists in one window, #1649), while
/// the client clears its cache only once a call returns. Only the latest
/// toggle of an address settles its row.
@MainActor
final class AddressFavoriteRefreshTests: XCTestCase {
    private static let target = Address(address: "pick@a.example", subdomain: "a", tld: "example")

    /// A refresh that read the list from before the call keeps the star.
    func testARefreshWhileTheCallIsOutKeepsTheAskedForFlag() async throws {
        let probe = Probe()
        let model = try makeModel(status: 200, probe: probe) { probe in
            await probe.model?.refresh(force: true)
            probe.seenDuringCall = probe.model?.addresses.first?.favorite
        }
        probe.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(probe.seenDuringCall, true, "the server's list from before the call, with the star laid over")
        XCTAssertEqual(model.addresses.first?.favorite, true)
        XCTAssertNil(model.errorMessage)
    }

    /// A refresh's write that lands mid-call is put right once the call
    /// lands.
    func testAFavoriteThatLandsSurvivesARefreshWhileItWasOut() async throws {
        let probe = Probe()
        let model = try makeModel(status: 200, probe: probe) { probe in probe.revert() }
        probe.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(model.addresses.first?.favorite, true)
        XCTAssertEqual(probe.changes, 1, "the other lists hear it")
    }

    /// The user unstars before the star's call lands; the unstar's call lands
    /// first. The star's success, later, leaves the row unstarred.
    func testAnOlderToggleLandingLateLeavesTheNewerFlag() async throws {
        let probe = Probe()
        let model = try makeModel(status: 200, probe: probe) { probe in
            guard let model = probe.model, let row = model.addresses.first else { return }
            await model.toggleFavorite(row)
        }
        probe.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(model.addresses.first?.favorite, false)
        XCTAssertEqual(probe.changes, 1, "only the toggle that settled the row")
    }

    func testAFavoriteThatFailsComesBackAndTellsNoOne() async throws {
        let probe = Probe()
        let model = try makeModel(status: 500, probe: probe) { probe in probe.revert() }
        probe.model = model

        await model.toggleFavorite(Self.target)

        XCTAssertEqual(model.addresses.first?.favorite, false)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(probe.changes, 0)
    }

    // MARK: - Fixtures

    private func makeModel(
        status: Int, probe: Probe, whileOut: @escaping @Sendable @MainActor (Probe) async -> Void
    ) throws -> AddressesViewModel {
        let transport = HookedTransport(status: status, list: [Self.target]) { await whileOut(probe) }
        let client = try TestFixtures.makeClient(imap: FakeImapClient(), transport: transport)
        let model = AddressesViewModel(client: client, changed: { probe.changes += 1 })
        model.addresses = [Self.target]
        return model
    }
}

/// The model under test, and what the test saw of it.
@MainActor
private final class Probe {
    var model: AddressesViewModel?
    var seenDuringCall: Bool?
    var changes = 0

    /// What a refresh that read the cache from before the call writes.
    func revert() {
        guard let model, !model.addresses.isEmpty else { return }
        model.addresses[0].favorite = false
    }
}

/// `/list` answers `list`; every other call answers `status`, running
/// `whileOut` first (once), while the caller is still waiting on it.
private struct HookedTransport: HTTPTransport {
    let status: Int
    let list: [Address]
    let whileOut: @Sendable () async -> Void
    private let gate = Gate()

    init(status: Int, list: [Address], whileOut: @escaping @Sendable () async -> Void) {
        self.status = status
        self.list = list
        self.whileOut = whileOut
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try XCTUnwrap(request.url)
        if url.path.hasSuffix("/list") {
            let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (try JSONEncoder().encode(list), ok)
        }
        if await gate.open() { await whileOut() }
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
        return (Data("{}".utf8), response)
    }
}

/// Lets the hook run for the first call only.
private actor Gate {
    private var opened = false

    func open() -> Bool {
        defer { opened = true }
        return !opened
    }
}
