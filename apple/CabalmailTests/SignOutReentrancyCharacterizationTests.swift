import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Workstream 0.8 characterization suite: what happens when a second
/// sign-out, or a sign-in, arrives while an expiry's teardown is under way.
/// Protects the #1703 contract that an expiry and a deliberate Sign Out share
/// one teardown, and `handleSessionExpiry`'s promise that a sign-out the user
/// asked for never ends on "your session expired".
///
/// The window: the teardown stops the pollers and the observer, then awaits
/// `sessionWillEnd` (in production, `PushRegistrar` awaiting
/// `/push_deregister`, a network call) with the client still wired and the
/// status still `.signedIn`. Here the expiry's teardown is held at the hook's
/// entry, standing in for the network wait. `signOut()` used to have no
/// guard for that window: a second sign-out ran the whole teardown again,
/// and a sign-in back was torn down by the stale one (#1829). Both now wait
/// for the teardown in flight (`SessionTeardownGate`).
@MainActor
final class SignOutReentrancyCharacterizationTests: XCTestCase {
    private var harness: SessionHarness!
    private var gate: HookGate?

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        gate?.release()
        gate = nil
        await harness?.tearDown()
        harness = nil
    }

    /// Settings ▸ Sign Out while an expiry's teardown waits in
    /// `sessionWillEnd` joins that teardown: every hook runs once, compose's
    /// session counter moves once, and the form the user signed out to has
    /// no "session expired" note. It used to run the whole teardown again,
    /// and the expiry's teardown then resumed over a session already gone and
    /// wrote its reason onto the user's form (#1829).
    func testASignOutDuringAnExpiryTeardownJoinsItAndEndsWithoutTheReason() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let gate = holdFirstSessionWillEnd()
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        let mark = harness.events.count

        state.sessionInvalidation.sessionDidExpire()
        await fulfillment(of: [gate.arrival], timeout: defaultWaitTimeout)
        XCTAssertEqual(state.status, .signedIn, "mid-teardown, the app still reads as signed in")
        XCTAssertNotNil(state.client)
        let signOut = Task { await state.signOut() }
        try await waitUntilOnMainActor { state.teardownGate.signOutRequests == 2 }
        XCTAssertEqual(state.status, .signedIn, "the user's sign-out waits for the expiry's")
        gate.release()
        await signOut.value
        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)

        XCTAssertEqual(Array(harness.events[mark...]), ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
        XCTAssertEqual(state.composeSlots.session, 1)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.client)
        XCTAssertNil(state.signedOutReason, "the user's own sign-out explains itself")
    }

    /// A sign-in back while an expiry's teardown waits starts only once the
    /// teardown is done, so the new session is whole: its tokens are stored,
    /// its observer listens, and it starts its own pollers (the badge prompt
    /// is asked for again). The stale teardown used to finish against the
    /// new session: it removed the new tokens, cleared the new cursor's
    /// resume state, dropped the new client and left the new observer and
    /// pollers running with the status on `.signedOut` (#1829).
    func testASignInDuringAnExpiryTeardownWaitsForItAndStartsWhole() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let gate = holdFirstSessionWillEnd()
        let staleObserver = try XCTUnwrap(state.sessionExpiryTask)
        state.sessionInvalidation.sessionDidExpire()
        await fulfillment(of: [gate.arrival], timeout: defaultWaitTimeout)
        let signOut = Task { await state.signOut() }
        try await waitUntilOnMainActor { state.teardownGate.signOutRequests == 2 }
        let mark = harness.events.count
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-2"))
        let signIn = Task {
            await state.signIn(controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password)
        }
        // Let the sign-in get as far as it can before the teardown resumes.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(state.status, .signedIn, "the sign-in waits for the teardown")

        gate.release()
        await signOut.value
        await signIn.value
        await SignOutSuiteSteps.awaitEnd(of: staleObserver, in: self)

        XCTAssertEqual(
            Array(harness.events[mark...]),
            ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"]
                + SignInScript.clientBuilt + SignInScript.wired("alice"),
            "the teardown ends before the sign-in starts, and the new session asks for the badge again"
        )
        XCTAssertEqual(state.status, .signedIn)
        XCTAssertNil(state.signedOutReason)
        XCTAssertTrue(harness.hasStoredTokens, "the new session's tokens survive")
        XCTAssertTrue(state.client === harness.clients.last)
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        XCTAssertFalse(observer.isCancelled, "the new session's observer listens")
        let feedPoll = try XCTUnwrap(state.feedRefreshTask)
        XCTAssertFalse(feedPoll.isCancelled)
    }

    // MARK: - Helpers

    /// Holds the first `sessionWillEnd` (before the harness records it)
    /// until the gate is released; later calls pass straight through.
    private func holdFirstSessionWillEnd() -> HookGate {
        let gate = HookGate(arrival: expectation(description: "a teardown reached sessionWillEnd"))
        let original = harness.appState.sessionEnvironment.hooks.sessionWillEnd
        harness.appState.sessionEnvironment.hooks.sessionWillEnd = {
            await gate.holdFirstCall()
            await original()
        }
        self.gate = gate
        return gate
    }
}

/// Holds the first caller until `release()`; later callers, and any after
/// the release, pass straight through. `arrival` is fulfilled once the first
/// caller is parked, so a test waits for it with a bound: a refactor that
/// stops routing the teardown through the hook fails as a timeout instead
/// of hanging the run.
@MainActor
private final class HookGate {
    let arrival: XCTestExpectation
    private var used = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    init(arrival: XCTestExpectation) {
        self.arrival = arrival
    }

    func holdFirstCall() async {
        guard !used, !released else { return }
        used = true
        await withCheckedContinuation { continuation in
            held = continuation
            arrival.fulfill()
        }
    }

    func release() {
        released = true
        held?.resume()
        held = nil
    }
}
