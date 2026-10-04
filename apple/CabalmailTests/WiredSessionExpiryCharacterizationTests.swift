import XCTest
import Observation
import CabalmailKit
@testable import Cabalmail

/// Workstream 0.8 characterization suite: `handleSessionExpiry()` with a
/// wired session (#1703). `SessionExpiryTeardownTests` and
/// `SessionLifecycleCharacterizationTests` pin the same paths with no client;
/// with one, the expiry runs the full `signOut()` teardown first and writes
/// its reason after, and a refused refresh on a real API call reaches the
/// observer end to end through the harness's client, mapped to an expired
/// session rather than a wrong password (#1288's refused-refresh mapping).
/// An expiry overlapped by a deliberate Sign Out is in
/// `SignOutReentrancyCharacterizationTests`.
@MainActor
final class WiredSessionExpiryCharacterizationTests: XCTestCase {
    private var harness: SessionHarness!

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    /// `signOut()` runs first (its hooks see no reason: it clears it), and
    /// the reason is written once the teardown has finished.
    func testAnExpiryWithAWiredSessionSignsOutFirstAndThenSetsTheReason() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let reasons = ReasonLog()
        let original = state.sessionEnvironment.hooks.sessionDidEnd
        state.sessionEnvironment.hooks.sessionDidEnd = { [weak state] in
            reasons.atDidEnd.append(state?.signedOutReason)
            original()
        }
        state.signedOutReason = .sessionExpired
        let mark = harness.events.count

        await state.handleSessionExpiry()

        XCTAssertEqual(reasons.atDidEnd, [nil], "signOut cleared the reason before its hooks ran")
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.client)
        XCTAssertNil(state.sessionExpiryTask)
        XCTAssertEqual(Array(harness.events[mark...]), ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
    }

    /// Once the observer's teardown has run, AppState has no listener left:
    /// a second announcement still goes out (a probe subscribed to the
    /// monitor hears it), but the observer has ended and nothing replaced
    /// it. And a second `handleSessionExpiry()`, what a doubly heard signal
    /// would run, returns at its status guard without writing anything: no
    /// teardown, no client, and the reason is not rewritten. Without the
    /// guard, `signOut()` would clear the reason and the expiry would set it
    /// again, two writes that leave the same value behind, so the writes are
    /// counted rather than the value read.
    func testASecondExpiryAfterTheTeardownChangesNothing() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        state.sessionInvalidation.sessionDidExpire()
        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)
        let events = harness.events
        let probe = state.sessionInvalidation.events()
        let reasonWrites = ReasonWriteTally(watching: state)

        state.sessionInvalidation.sessionDidExpire()
        let heard = await bufferedCount(probe)
        await state.handleSessionExpiry()

        XCTAssertEqual(heard, 1, "the announcement went out")
        XCTAssertNil(state.sessionExpiryTask, "with no observer of AppState's left to hear it")
        XCTAssertEqual(reasonWrites.count, 0, "the status guard returned before signOut()")
        XCTAssertEqual(harness.events, events)
        XCTAssertEqual(harness.clients.count, 1)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
    }

    /// End to end through the session's own client: the stored ID token has
    /// lapsed, Cognito refuses the refresh (`NotAuthorizedException`), so the
    /// API call dies before it is sent with `.authExpired`, the Kit announces
    /// the expiry, and the observer tears the session down with a reason.
    func testARefusedRefreshOnAnApiCallTearsTheSessionDown() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let client = try XCTUnwrap(state.client)
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        try await harness.seedTokens(id: "ID-STALE", expiresIn: -60)
        await harness.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "Token expired"))
        let mark = harness.events.count

        do {
            _ = try await client.apiClient.listAddresses()
            XCTFail("expected the refused refresh to surface as an expired session")
        } catch let error as CabalmailError {
            XCTAssertEqual(error, .authExpired, "the throw the call site still renders")
        }
        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertNil(state.client)
        XCTAssertFalse(harness.hasStoredTokens)
        XCTAssertEqual(Array(harness.events[mark...]), ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
        let trail = await harness.cognito.trail
        XCTAssertEqual(trail, ["InitiateAuth USER_PASSWORD_AUTH", "InitiateAuth REFRESH_TOKEN_AUTH"])
    }
}

@MainActor
private final class ReasonLog {
    var atDidEnd: [SignedOutReason?] = []
}

/// Counts the changes Observation announces for `signedOutReason`. Holds the
/// state weakly, so it never keeps a harness's state alive.
@MainActor
private final class ReasonWriteTally {
    private(set) var count = 0
    private weak var state: AppState?

    init(watching state: AppState) {
        self.state = state
        arm()
    }

    /// Tracking is one-shot, so each change re-arms it. The callback runs
    /// synchronously inside the write, which here is always on the main actor.
    private func arm() {
        withObservationTracking {
            _ = state?.signedOutReason
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
                self?.arm()
            }
        }
    }
}
