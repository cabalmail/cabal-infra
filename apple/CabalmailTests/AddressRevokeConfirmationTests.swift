import XCTest
import CabalmailKit
@testable import CabalmailUI

/// #1454: revoking an address from the Addresses list raised no confirmation,
/// while the same action from the reader's per-address menu raises
/// `Toast.addressRevoked` and the *create* path on the very same screen
/// raises `Toast.addressCreated`. The row simply vanished.
///
/// The list's revoke could not confirm itself because
/// `AddressesViewModel.revoke` returned `Void`: success and failure were
/// indistinguishable to the caller, and the failure path's only signal is
/// `errorMessage`, which the list already renders as a banner. So the fix is
/// the model reporting the outcome, and these are the tests for that —
/// whether the view then raises the toast is view wiring with no unit seam,
/// and is verified live (see the PR).
@MainActor
final class AddressRevokeConfirmationTests: XCTestCase {

    /// The half the confirmation hangs on: a revoke that lands says so.
    func testASuccessfulRevokeReportsSuccess() async throws {
        let model = try makeModel(status: 200)
        let landed = await model.revoke(Self.target)
        XCTAssertTrue(landed)
    }

    /// And a revoke that does not land must not, or the list would confirm
    /// an address that is still live — strictly worse than the silence being
    /// fixed, because it would be wrong rather than merely absent.
    func testAFailedRevokeReportsFailure() async throws {
        let model = try makeModel(status: 500)
        let landed = await model.revoke(Self.target)
        XCTAssertFalse(landed)
    }

    /// The outcome the caller reads and the outcome the list shows have to
    /// agree: the row goes on success and stays on failure. Asserted here so
    /// a future change cannot make the return value a second, drifting
    /// opinion about what happened.
    func testTheReturnedOutcomeMatchesWhatHappenedToTheRow() async throws {
        let succeeding = try makeModel(status: 200)
        _ = await succeeding.revoke(Self.target)
        XCTAssertEqual(succeeding.addresses.map(\.address), ["keep@b.example"])
        XCTAssertNil(succeeding.errorMessage)

        let failing = try makeModel(status: 500)
        _ = await failing.revoke(Self.target)
        XCTAssertEqual(
            failing.addresses.map(\.address), [Self.target.address, "keep@b.example"]
        )
        XCTAssertNotNil(failing.errorMessage)
    }

    /// A revoke or a suspension that lands tells the other address lists,
    /// through the hook the view hands the model
    /// (`AppState.addressesChanged()`); one that fails tells no one.
    func testOnlyAChangeThatLandsTellsTheOtherLists() async throws {
        let landing = Changes()
        let landed = try makeModel(status: 200, changes: landing)
        _ = await landed.revoke(Self.target)
        await landed.setSuspended(Self.kept, to: true)
        await landed.setSuspended(Self.kept, to: false)
        XCTAssertEqual(landing.count, 3)

        let failing = Changes()
        let failed = try makeModel(status: 500, changes: failing)
        _ = await failed.revoke(Self.target)
        await failed.setSuspended(Self.kept, to: true)
        XCTAssertEqual(failing.count, 0)
    }

    // MARK: - Fixtures

    private static let target = Address(
        address: "burn@a.example", subdomain: "a", tld: "example"
    )
    private static let kept = Address(address: "keep@b.example", subdomain: "b", tld: "example")

    /// How many times the model told the other lists.
    private final class Changes {
        var count = 0
    }

    private func makeModel(status: Int, changes: Changes? = nil) throws -> AddressesViewModel {
        let client = try TestFixtures.makeClient(
            imap: FakeImapClient(), transport: FixedStatusTransport(status: status)
        )
        let model = AddressesViewModel(client: client, changed: { changes?.count += 1 })
        model.addresses = [Self.target, Self.kept]
        return model
    }
}

/// Answers every request with the same status and an empty JSON object.
/// `/revoke` sends a DELETE and only checks the status, so the status is the
/// whole of what the two arms differ by.
private struct FixedStatusTransport: HTTPTransport {
    let status: Int

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
}
