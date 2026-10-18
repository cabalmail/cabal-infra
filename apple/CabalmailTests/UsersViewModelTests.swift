import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `UsersViewModel` against a scripted `UsersBackend` (auth parity plan, C2):
/// the pending / confirmed split, the hidden system accounts, each action,
/// the self guard, the optimistic domain toggle, and the 403 path.
@MainActor
final class UsersViewModelTests: XCTestCase {
    private let domains = ["cabalmail.example", "other.example"]

    private func makeModel(
        _ backend: FakeUsersBackend,
        currentUsername: String = "admin",
        onAccessDenied: @escaping @MainActor () async -> Void = {}
    ) -> UsersViewModel {
        UsersViewModel(backend: backend, domains: domains, currentUsername: currentUsername,
                       onAccessDenied: onAccessDenied)
    }

    private func loadedModel(_ backend: FakeUsersBackend = FakeUsersBackend.standard()) async -> UsersViewModel {
        let model = makeModel(backend)
        await model.load()
        return model
    }

    func testLoadSplitsPendingFromConfirmedAndHidesTheSystemAccounts() async {
        let model = await loadedModel()

        XCTAssertEqual(model.pending.map(\.username), ["newbie", "resetter"])
        XCTAssertEqual(model.confirmed.map(\.username), ["admin", "alice", "zed"])
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasAttemptedLoad)
        XCTAssertNil(model.loadError)
        XCTAssertTrue(model.hasAccess("alice", to: "cabalmail.example"))
        XCTAssertFalse(model.hasAccess("alice", to: "other.example"))
    }

    func testALoadFailureShowsAnErrorAndARetryRecovers() async {
        let backend = FakeUsersBackend.standard()
        backend.listError = CabalmailError.network("offline")
        let model = makeModel(backend)
        await model.load()
        XCTAssertNotNil(model.loadError)
        XCTAssertTrue(model.pending.isEmpty)

        backend.listError = nil
        await model.load()
        XCTAssertNil(model.loadError)
        XCTAssertEqual(model.confirmed.count, 3)
    }

    /// Toggles drawn without the allow list would all read as off, so its
    /// failure fails the load rather than showing them.
    func testTheAllowListFailingFailsTheLoad() async {
        let backend = FakeUsersBackend.standard()
        backend.allowanceError = CabalmailError.network("offline")
        let model = makeModel(backend)
        await model.load()
        XCTAssertNotNil(model.loadError)
    }

    func testA403OnLoadShowsAdministratorsOnlyAndRereadsAdminStatus() async {
        let backend = FakeUsersBackend.standard()
        backend.listError = CabalmailError.http(status: 403, body: #"{"Error":"Admin access required"}"#)
        let reread = CallCounter()
        let model = makeModel(backend, onAccessDenied: { reread.count += 1 })
        await model.load()

        XCTAssertTrue(model.accessDenied)
        XCTAssertNil(model.loadError, "a 403 is the access-denied state, not a load error")
        XCTAssertEqual(reread.count, 1)
    }

    func testConfirmingMarksTheAccountConfirmed() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)

        await model.confirm("newbie")

        XCTAssertEqual(backend.calls.last, "confirm newbie")
        XCTAssertEqual(model.pending.map(\.username), ["resetter"])
        XCTAssertTrue(model.confirmed.map(\.username).contains("newbie"))
    }

    func testDisablingAndEnablingFlipSignIn() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)

        await model.setEnabled("alice", enabled: false)
        XCTAssertEqual(model.user(named: "alice")?.enabled, false)
        await model.setEnabled("alice", enabled: true)
        XCTAssertEqual(model.user(named: "alice")?.enabled, true)
        XCTAssertEqual(backend.calls.suffix(2), ["setEnabled alice false", "setEnabled alice true"])
    }

    /// The server only refuses deleting yourself; disabling yourself would
    /// lock you out, so neither leaves the device.
    func testYourOwnAccountIsNeitherDisabledNorDeleted() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)
        let callsBefore = backend.calls

        await model.setEnabled("admin", enabled: false)
        let deleted = await model.delete("admin")

        XCTAssertFalse(deleted)
        XCTAssertEqual(backend.calls, callsBefore)
        XCTAssertEqual(model.user(named: "admin")?.enabled, true)
    }

    func testDeletingRemovesTheAccountAndItsGrants() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)

        let deleted = await model.delete("alice")

        XCTAssertTrue(deleted)
        XCTAssertEqual(backend.calls.last, "delete alice")
        XCTAssertNil(model.user(named: "alice"))
        XCTAssertFalse(model.hasAccess("alice", to: "cabalmail.example"))
    }

    func testADomainToggleMovesAtOnceAndBackWhenRefused() async throws {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)
        backend.holdActions = true

        let grant = Task { await model.setAccess("alice", to: "other.example", allowed: true) }
        try await waitUntilOnMainActor { backend.heldCount == 1 }
        XCTAssertTrue(model.hasAccess("alice", to: "other.example"), "the toggle moves before the reply")
        XCTAssertTrue(model.busy.contains("alice"))

        let refusal = #"{"Error":"Unknown domain \"other.example\""}"#
        backend.release(failing: CabalmailError.http(status: 400, body: refusal))
        await grant.value
        XCTAssertFalse(model.hasAccess("alice", to: "other.example"), "and moves back when the server refuses")
        XCTAssertFalse(model.busy.contains("alice"))
        XCTAssertEqual(model.actionError?.title, "Couldn't grant alice's access to other.example")
        XCTAssertEqual(model.actionError?.message, #"Unknown domain "other.example"."#)
    }

    func testRevokingAccessSendsAllowedFalse() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)

        await model.setAccess("alice", to: "cabalmail.example", allowed: false)

        XCTAssertEqual(backend.calls.last, "setDomainAccess alice cabalmail.example false")
        XCTAssertFalse(model.hasAccess("alice", to: "cabalmail.example"))
        XCTAssertNil(model.actionError)
    }

    func testAFailedActionRaisesAnAlertWithTheServersSentence() async {
        let backend = FakeUsersBackend.standard()
        let model = await loadedModel(backend)
        backend.actionError = CabalmailError.http(status: 500, body: #"{"Error":"boom"}"#)

        await model.confirm("newbie")

        XCTAssertEqual(model.actionError?.title, "Couldn't confirm newbie")
        XCTAssertEqual(model.pending.map(\.username), ["newbie", "resetter"], "nothing changes on a failure")
    }

    func testA403OnAnActionShowsAdministratorsOnly() async {
        let backend = FakeUsersBackend.standard()
        let reread = CallCounter()
        let model = makeModel(backend, onAccessDenied: { reread.count += 1 })
        await model.load()
        backend.actionError = CabalmailError.http(status: 403, body: #"{"Error":"Admin access required"}"#)

        await model.setEnabled("alice", enabled: false)

        XCTAssertTrue(model.accessDenied)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(reread.count, 1)
    }

    func testSettingsListsUsersOnlyForAnAdministrator() {
        XCTAssertFalse(SettingsCategory.listed(isAdmin: false).contains(.users))
        let forAdmin = SettingsCategory.listed(isAdmin: true)
        XCTAssertTrue(forAdmin.contains(.users))
        XCTAssertEqual(forAdmin.filter { $0 != .users }, SettingsCategory.listed(isAdmin: false))
    }
}

/// Counts calls from a main-actor closure.
@MainActor
private final class CallCounter {
    var count = 0
}

/// Scripted `UsersBackend`: canned reads, recorded calls, an optional error
/// for every action, and actions that can be held on a continuation.
private final class FakeUsersBackend: UsersBackend, @unchecked Sendable {
    var users: [PoolUser] = []
    var allowances: [DomainAllowance] = []
    var listError: Error?
    var allowanceError: Error?
    var actionError: Error?
    var holdActions = false
    private(set) var calls: [String] = []
    private var held: [CheckedContinuation<Void, Error>] = []
    var heldCount: Int { held.count }

    static func standard() -> FakeUsersBackend {
        let backend = FakeUsersBackend()
        backend.users = [
            PoolUser(username: "zed", status: "CONFIRMED", enabled: true),
            PoolUser(username: "admin", status: "CONFIRMED", enabled: true),
            PoolUser(username: "alice", status: "CONFIRMED", enabled: true, osid: "2001"),
            PoolUser(username: "newbie", status: "UNCONFIRMED", enabled: true),
            PoolUser(username: "resetter", status: "FORCE_CHANGE_PASSWORD", enabled: true),
            PoolUser(username: "master", status: "CONFIRMED", enabled: true),
            PoolUser(username: "dmarc", status: "CONFIRMED", enabled: true),
            PoolUser(username: "ci-probe", status: "CONFIRMED", enabled: true),
        ]
        backend.allowances = [DomainAllowance(user: "alice", domain: "cabalmail.example")]
        return backend
    }

    func listUsers() async throws -> [PoolUser] {
        if let listError { throw listError }
        return users
    }

    func listDomainAccess() async throws -> [DomainAllowance] {
        if let allowanceError { throw allowanceError }
        return allowances
    }

    func confirm(_ username: String) async throws { try await act("confirm \(username)") }
    func setEnabled(_ username: String, enabled: Bool) async throws {
        try await act("setEnabled \(username) \(enabled)")
    }
    func delete(_ username: String) async throws { try await act("delete \(username)") }

    func setDomainAccess(user: String, domain: String, allowed: Bool) async throws {
        try await act("setDomainAccess \(user) \(domain) \(allowed)")
    }

    func release(failing error: Error? = nil) {
        let waiting = held
        held = []
        for continuation in waiting {
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }

    private func act(_ call: String) async throws {
        calls.append(call)
        if holdActions {
            try await withCheckedThrowingContinuation { held.append($0) }
        }
        if let actionError { throw actionError }
    }
}
