import Synchronization
import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What the launch restore does when the keychain fails mid-restore (#1808).
///
/// The keychain reports its failures as `.storage`, which `OfflineLaunch`
/// does not take for "Cognito unreachable", so a refresh that succeeded but
/// could not be saved no longer passes as an offline launch. `.storage` is
/// not in the restore's transient arm either, so it lands on `.error` with
/// its own text and the stored tokens kept for a later launch. Before, the
/// session was wired with the expired pair it could not replace.
///
/// A keychain that can't be read at all is a different case, pinned in
/// `RestoreGuardCharacterizationTests`: the restore reads the tokens with
/// `try?` first, builds nothing, and leaves the status as it was.
@MainActor
final class RestoreStorageFailureTests: XCTestCase {
    private var harness: SessionHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
        harness.seedLastSession()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testARefreshThatCannotBeSavedEndsOnTheErrorStatusKeepingTheTokens() async throws {
        try await harness.seedTokens(id: "ID-1", expiresIn: -60)
        let blob = try harness.secureStore.get(SecureStoreKey.authTokens)
        await harness.cognito.script(.refresh, .tokens(id: "ID-2"))
        let failing = WriteFailingSecureStore()
        let makeStore = harness.appState.sessionManager.sessionEnvironment.makeSecureStore
        harness.appState.sessionManager.sessionEnvironment.makeSecureStore = {
            failing.base = makeStore()
            return failing
        }
        let announcements = harness.appState.sessionManager.sessionInvalidation.events()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(
            harness.appState.status,
            .error("Couldn't read or save data on this device. Keychain write failed: -25308.")
        )
        XCTAssertNil(harness.appState.signedOutReason, "not an expiry")
        XCTAssertNil(harness.appState.client, "no session is wired")
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth REFRESH_TOKEN_AUTH"], "the refresh reached Cognito and succeeded")
        XCTAssertEqual(failing.failedWrites, 1)
        XCTAssertEqual(try harness.secureStore.get(SecureStoreKey.authTokens), blob, "the expired pair is kept")
        let count = await bufferedCount(announcements)
        XCTAssertEqual(count, 0, "a device failure is not an ended session")
    }
}

/// A secure store whose writes fail the way `KeychainSecureStore` reports a
/// failing OSStatus; reads and removals reach the store it wraps, which the
/// environment hands it when the restore asks for a store.
private final class WriteFailingSecureStore: SecureStore {
    private let state = Mutex<(base: (any SecureStore)?, failures: Int)>((nil, 0))

    var base: any SecureStore {
        get { state.withLock { $0.base! } }
        set { state.withLock { $0.base = newValue } }
    }

    var failedWrites: Int { state.withLock { $0.failures } }

    func set(_ value: Data, forKey key: String) throws {
        state.withLock { $0.failures += 1 }
        throw CabalmailError.storage("Keychain write failed: -25308")
    }

    func get(_ key: String) throws -> Data? { try base.get(key) }
    func remove(_ key: String) throws { try base.remove(key) }
}
