import XCTest
import CabalmailKit
@testable import Cabalmail

/// Workstream 0.8 characterization suite: `AppState.signOut()` is not
/// re-entrant, and both ways a second teardown can overlap an expiry's are
/// pinned here, so the per-account session manager (workstream 1.3) changes
/// them on purpose. Protects the #1703 contract that an expiry and a
/// deliberate Sign Out share one teardown, and `handleSessionExpiry`'s
/// promise that a sign-out the user asked for never ends on "your session
/// expired".
///
/// The window: `signOut()` stops the pollers and the observer, then awaits
/// `sessionWillEnd` (in production, `PushRegistrar` awaiting
/// `/push_deregister`, a network call) with the client still wired and the
/// status still `.signedIn`. Its no-client guard tests only `client`, and
/// `handleSessionExpiry`'s status guard was passed before the wait, so
/// neither stops a second entry. Settings ▸ Sign Out disables only its own
/// button while it runs. Here the expiry's teardown is held at the hook's
/// entry, standing in for the network wait.
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

    /// Pins current behaviour, which looks like a defect: Settings ▸ Sign
    /// Out while an expiry's teardown waits in `sessionWillEnd` runs the
    /// whole teardown again and ends on the blank form. The expiry's
    /// teardown then resumes over a session that is already gone: its
    /// `sessionWillEnd` finishes after the tokens were wiped, every hook runs
    /// twice, compose's session counter moves by two, and once it returns
    /// `handleSessionExpiry` writes "your session expired" onto the form the
    /// user signed out to.
    /// Tracked in #1829.
    func testASignOutDuringAnExpiryTeardownRunsItAgainAndEndsOnTheExpiryReason() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let gate = holdFirstSessionWillEnd()
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        let mark = harness.events.count

        state.sessionInvalidation.sessionDidExpire()
        await fulfillment(of: [gate.arrival], timeout: defaultWaitTimeout)
        XCTAssertEqual(state.status, .signedIn, "mid-teardown, the app still reads as signed in")
        XCTAssertNotNil(state.client)
        await state.signOut()
        XCTAssertNil(state.signedOutReason, "the user's sign-out ends on the blank form, for now")
        gate.release()
        await SignOutSuiteSteps.awaitEnd(of: observer, in: self)

        XCTAssertEqual(Array(harness.events[mark...]), [
            "sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone",
            "sessionWillEnd tokens=gone", "sessionDidEnd tokens=gone",
        ])
        XCTAssertEqual(state.composeSlots.session, 2)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.client)
        XCTAssertEqual(state.signedOutReason, .sessionExpired, "the expiry's reason lands on the user's sign-out")
    }

    /// Pins current behaviour, which looks like a defect: when the user
    /// signs out and back in before an expiry's teardown resumes, the stale
    /// teardown finishes against the new session. Its `client` local is the
    /// old one, but the old auth service's sign-out removes the new
    /// session's tokens (one keychain item in production, one store here),
    /// and everything after it acts on what is wired now: the new cursor's
    /// resume state is cleared, the new client and cursor are dropped, and
    /// the status flips to `.signedOut` with the expiry's reason. The new
    /// session's observer and feed poller keep running (the stale teardown
    /// stopped the pollers before it suspended), and so does its badge
    /// poller: the next sign-in requests no badge authorization and starts
    /// no poller of its own. In production `clearLocalData()` also wipes the
    /// shared cache directory under the new session; the harness gives each
    /// client its own, so that part is not observable here.
    /// Tracked in #1829.
    func testASignInBeforeAnExpiryTeardownResumesIsTornDownByIt() async throws {
        await SignOutSuiteSteps.signIn(harness)
        let state = harness.appState
        let gate = holdFirstSessionWillEnd()
        let staleObserver = try XCTUnwrap(state.sessionExpiryTask)
        state.sessionInvalidation.sessionDidExpire()
        await fulfillment(of: [gate.arrival], timeout: defaultWaitTimeout)
        await state.signOut()
        await SignOutSuiteSteps.signIn(harness, idToken: "ID-2")
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        let feedPoll = try XCTUnwrap(state.feedRefreshTask)
        let cursor = try XCTUnwrap(state.navCoordinator)
        cursor.recordFolder("Archive")
        cursor.flushSession()
        let resume = ResumeSessionStore(defaults: harness.defaults)
        XCTAssertEqual(resume.loadSession()?.folder, "Archive", "precondition")
        let mark = harness.events.count

        gate.release()
        await SignOutSuiteSteps.awaitEnd(of: staleObserver, in: self)

        XCTAssertEqual(Array(harness.events[mark...]), ["sessionWillEnd tokens=stored", "sessionDidEnd tokens=gone"])
        XCTAssertFalse(harness.hasStoredTokens, "the old client's sign-out removed the new session's tokens")
        XCTAssertNil(resume.loadSession(), "the new cursor's resume state was cleared")
        XCTAssertNil(state.client)
        XCTAssertNil(state.navCoordinator)
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertEqual(state.sessionExpiryTask, observer, "the new session's observer still listens")
        XCTAssertFalse(observer.isCancelled)
        XCTAssertEqual(state.feedRefreshTask, feedPoll)
        XCTAssertFalse(feedPoll.isCancelled, "and its feed poller still polls")

        let beforeThird = harness.events.count
        await SignOutSuiteSteps.signIn(harness, idToken: "ID-3")
        let third = Array(harness.events[beforeThird...])
        XCTAssertFalse(third.contains("requestBadgeAuthorization"), "the leftover badge poller blocks a fresh one")
        XCTAssertTrue(third.contains("requestContactsAccess"), "the rest of the wiring ran")
        XCTAssertEqual(state.feedRefreshTask, feedPoll, "as does the leftover feed poller")
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
