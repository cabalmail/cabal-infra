import XCTest
import Observation
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 of the rearchitecture proposal.
/// `AppState` is about to split into per-window navigation and a per-account
/// session, and nothing pinned how its session lifecycle behaves; these record
/// it as it is today, quirks included, so the move shows any change. A quirk
/// that looks wrong is pinned anyway and says so.
///
/// `AppState` has no injection seam, so only the branches that never reach
/// the keychain, the network, `UserDefaults.standard` or an OS prompt are
/// here, and every test runs with no client wired:
///
/// - `restoreIfPossible()` is a pure no-op while signing in or restoring: the
///   idempotence both launch-restore call sites rely on. The signed-in no-op
///   is not pinned: production is never `.signedIn` without a client, so it
///   returns at the `client == nil` guard, which needs a client to reach.
/// - `submitMfaCode(_:)` with no challenge parked, and `cancelMfaChallenge()`.
///   The parked-challenge halves (mismatch, success) need a session seam.
/// - `handleSessionExpiry()` from the states `SessionExpiryTeardownTests`
///   leaves out (#1703); that suite covers `.signedIn` and `.signedOut`.
///
/// `SessionObserverCharacterizationTests` below pins the observer that calls
/// `handleSessionExpiry()`; `SessionTeardownCharacterizationTests` pins what a
/// sign-out with no client stops and leaves behind.
@MainActor
final class SessionLifecycleCharacterizationTests: XCTestCase {
    private static let mismatch = "That code did not match. Please try again."
    private static let sentinelError = "set by the test, not by AppState"

    // MARK: - restoreIfPossible while a session is in flight

    func testRestoreWhileSigningInIsANoOp() async {
        await assertRestoreLeavesEverythingAlone(in: .signingIn)
    }

    /// The second of two launch restores (the app entry's `.task` and a
    /// compose scene's) lands here: the first set `.restoring` synchronously.
    func testRestoreWhileRestoringIsANoOp() async {
        await assertRestoreLeavesEverythingAlone(in: .restoring)
    }

    /// Sentinels for everything the restore path writes when it runs: `status`
    /// on every branch, `signedOutReason` on the expiry branch, and a client,
    /// navigation cursor and session observer on success.
    ///
    /// If one of these fails, restore has already gone past its guards: it
    /// read the host's real `cabalmail.controlDomain` / `lastUsername`
    /// defaults and the login keychain (the same reads the host app's own
    /// launch restore makes), and with stored tokens it went on to the
    /// network. Treat such a failure as a behaviour change, not a flake.
    private func assertRestoreLeavesEverythingAlone(
        in status: AppState.Status,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = AppState()
        state.status = status
        state.signedOutReason = .sessionExpired
        state.mfaError = Self.sentinelError

        await state.restoreIfPossible()

        XCTAssertEqual(state.status, status, "restore must not move \(status)", file: file, line: line)
        XCTAssertEqual(state.signedOutReason, .sessionExpired, file: file, line: line)
        XCTAssertEqual(state.mfaError, Self.sentinelError, file: file, line: line)
        XCTAssertNil(state.client, file: file, line: line)
        XCTAssertNil(state.navCoordinator, file: file, line: line)
        XCTAssertNil(state.sessionExpiryTask, "no observer without a wired session", file: file, line: line)
    }

    // MARK: - Second factor with no challenge parked

    /// Only `signIn` parks a challenge. With none parked the guard sends the
    /// user back to the password form and writes `status` only: it returns
    /// before the code form's error is cleared, and leaves the reason alone.
    func testSubmittingWithNoChallengeParkedReturnsToThePasswordForm() async {
        let state = AppState()
        state.status = .mfaCodeRequired(.totp)
        state.mfaError = Self.mismatch
        state.signedOutReason = .sessionExpired

        await state.submitMfaCode("123456")

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.mfaError, Self.mismatch, "the guard returns before mfaError is cleared")
        XCTAssertEqual(state.signedOutReason, .sessionExpired, "the guard's exit writes status only")
    }

    /// Any state that is not the code form takes the same exit; an error's
    /// text is dropped for the blank form.
    func testSubmittingFromAnErrorDropsItForTheBlankForm() async {
        let state = AppState()
        state.status = .error("Network error: offline")

        await state.submitMfaCode("123456")

        XCTAssertEqual(state.status, .signedOut)
    }

    /// Pins current behaviour, which looks like a latent defect: the guard's
    /// exit writes `status` and nothing else, so a submit that arrives once a
    /// session is wired shows the sign-in form over a session that keeps
    /// running (with a client, the client would stay wired too). SignInView
    /// cannot send one today: it offers the form only in `.mfaCodeRequired`
    /// and guards re-entry. The session observer and the feed poller stand in
    /// for the session: no `signOut()` ran, so both are still running.
    /// Tracked in #1826.
    func testAStraySubmitWhileSignedInFlipsStatusWithoutATeardown() async throws {
        let state = AppState()
        state.status = .signedIn
        state.observeSessionInvalidation()
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        let feedPoll = Self.parkedTask()
        state.feedRefreshTask = feedPoll
        defer { observer.cancel(); feedPoll.cancel() }

        await state.submitMfaCode("123456")

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertFalse(observer.isCancelled, "no teardown ran")
        XCTAssertNotNil(state.sessionExpiryTask)
        XCTAssertFalse(feedPoll.isCancelled, "the feed poller keeps polling")
        XCTAssertNotNil(state.feedRefreshTask)
    }

    /// `pendingMfa` is private and only `signIn` sets it, so that this clears
    /// a parked challenge cannot be observed here; the error and the status
    /// can. The reason is left alone.
    func testCancellingTheChallengeClearsItsErrorAndSignsOut() {
        let state = AppState()
        state.status = .mfaCodeRequired(.sms)
        state.mfaError = Self.mismatch
        state.signedOutReason = .sessionExpired

        state.cancelMfaChallenge()

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertNil(state.mfaError)
        XCTAssertEqual(state.signedOutReason, .sessionExpired, "backing out writes no reason of its own")
    }

    /// Pins current behaviour, which looks like a latent defect: the same
    /// status-only exit as the stray submit above. The Back button that calls
    /// this exists only on the code form, so the app cannot reach it today.
    /// Tracked in #1826.
    func testCancellingWhileSignedInFlipsStatusWithoutATeardown() throws {
        let state = AppState()
        state.status = .signedIn
        state.observeSessionInvalidation()
        let observer = try XCTUnwrap(state.sessionExpiryTask)
        let feedPoll = Self.parkedTask()
        state.feedRefreshTask = feedPoll
        defer { observer.cancel(); feedPoll.cancel() }

        state.cancelMfaChallenge()

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertFalse(observer.isCancelled, "no teardown ran")
        XCTAssertFalse(feedPoll.isCancelled, "the feed poller keeps polling")
    }

    // MARK: - Expiry from the states SessionExpiryTeardownTests leaves out

    /// Pins current behaviour, which looks like a defect: the guard excludes
    /// only `.signedOut`, so an expiry replaces an unrelated error's text with
    /// "your session expired" although no session was live. The observer runs
    /// only between `wireSession` and `signOut`, so today only a direct call
    /// reaches this state.
    /// Tracked in #1826.
    func testAnExpiryFromAnErrorSignsOutWithAReason() async {
        await assertExpirySignsOutWithAReason(from: .error("Network error: offline"))
    }

    /// Pins current behaviour, which looks like a defect: the same guard lets
    /// an expiry take down the code form, though no session exists until the
    /// code is accepted.
    /// Tracked in #1826.
    func testAnExpiryFromTheCodeFormSignsOutWithAReason() async {
        await assertExpirySignsOutWithAReason(from: .mfaCodeRequired(.totp))
    }

    /// `signOut()` never touches `mfaError`, so the code form's error outlives
    /// the expiry. Unseen today: the form is gone, and `signIn` clears the
    /// error before the next challenge.
    func testAnExpiryFromTheCodeFormLeavesItsErrorBehind() async {
        let state = AppState()
        state.status = .mfaCodeRequired(.sms)
        state.mfaError = Self.mismatch

        await state.handleSessionExpiry()

        XCTAssertEqual(state.mfaError, Self.mismatch)
    }

    /// Matches what restore's own expiry branch produces (`.signedOut` with
    /// `.sessionExpired`), so this one is consistent rather than a quirk.
    func testAnExpiryWhileRestoringSignsOutWithAReason() async {
        await assertExpirySignsOutWithAReason(from: .restoring)
    }

    /// Pins current behaviour, which looks like a defect: an expiry during a
    /// sign-in signs out with a reason, and the sign-in in flight would then
    /// wire `.signedIn` over it with the reason still set, because only
    /// `signIn`'s synchronous prologue and `signOut` clear it (`wireSession`
    /// never does).
    /// Tracked in #1826.
    func testAnExpiryWhileSigningInSignsOutWithAReason() async {
        await assertExpirySignsOutWithAReason(from: .signingIn)
    }

    private func assertExpirySignsOutWithAReason(
        from status: AppState.Status,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let state = AppState()
        state.status = status

        await state.handleSessionExpiry()

        XCTAssertEqual(state.status, .signedOut, "expiry from \(status)", file: file, line: line)
        XCTAssertEqual(state.signedOutReason, .sessionExpired, file: file, line: line)
    }

    /// Stands in for a session poller: runs until cancelled.
    private static func parkedTask() -> Task<Void, Never> {
        Task { try? await Task.sleep(for: .seconds(3600)) }
    }
}

/// Characterization suite for workstream 0.8: the observer that turns the
/// Kit's invalidation signal into `handleSessionExpiry()` (#1703, d8f83c68).
/// `AppState`'s own monitor is reachable as `sessionInvalidation`, so these
/// signal it directly. Determinism comes from awaiting each observer task's
/// end, bounded by `defaultWaitTimeout`; nothing sleeps.
@MainActor
final class SessionObserverCharacterizationTests: XCTestCase {
    /// Signing back in calls `observeSessionInvalidation()` again: the first
    /// observer is cancelled and ends without hearing anything. A signal sent
    /// after that reaches the second, whose teardown also cancels and drops
    /// itself.
    ///
    /// The post-signal assertions pin only the end state. They cannot tell one
    /// teardown from two: a second `handleSessionExpiry()` would return at the
    /// status guard. The cancel and the first observer's end are the checks;
    /// `testASignalBufferedBeforeObservingAgainTearsDownOnceBecauseOfTheGuard`
    /// shows what keeps a doubly heard signal to one teardown.
    func testObservingAgainCancelsAndEndsTheFirstObserver() async throws {
        let state = AppState()
        state.status = .signedIn
        state.observeSessionInvalidation()
        let first = try XCTUnwrap(state.sessionExpiryTask)

        state.observeSessionInvalidation()
        let second = try XCTUnwrap(state.sessionExpiryTask)

        XCTAssertTrue(first.isCancelled, "signing back in must not leave two observers")
        XCTAssertFalse(second.isCancelled)
        await awaitEnd(of: first)

        state.sessionInvalidation.sessionDidExpire()
        // The teardown cancels its own observer, so its end is the moment the
        // state is final.
        await awaitEnd(of: second)

        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertNil(state.sessionExpiryTask)
    }

    /// Each observer subscribes synchronously, so a signal sent before the
    /// first observer has run is buffered in both streams, and a cancelled
    /// `AsyncStream` still hands over what it buffered: both observers call
    /// `handleSessionExpiry()`. Pins that the status guard, not the cancel,
    /// keeps that to one teardown. Each teardown writes the reason twice
    /// (`nil` in `signOut`, then `.sessionExpired`); starting from a reason
    /// makes both writes real changes, so the count does not depend on
    /// whether Observation skips an unchanged write.
    func testASignalBufferedBeforeObservingAgainTearsDownOnceBecauseOfTheGuard() async throws {
        let state = AppState()
        state.status = .signedIn
        state.signedOutReason = .sessionExpired
        let reasonWrites = ReasonWriteCounter(watching: state)
        state.observeSessionInvalidation()
        let first = try XCTUnwrap(state.sessionExpiryTask)
        state.observeSessionInvalidation()
        let second = try XCTUnwrap(state.sessionExpiryTask)

        state.sessionInvalidation.sessionDidExpire()
        await awaitEnd(of: first)
        await awaitEnd(of: second)

        XCTAssertEqual(reasonWrites.count, 2, "one teardown: two observers heard, the guard turned one away")
        XCTAssertEqual(state.status, .signedOut)
        XCTAssertEqual(state.signedOutReason, .sessionExpired)
        XCTAssertNil(state.sessionExpiryTask)
    }

    /// Pins that a sign-out cancels the observer and that it ends, so no later
    /// signal has a listener. With the observer finished there is nothing left
    /// to assert about a later signal without waiting for a non-event.
    func testSignOutCancelsAndEndsTheObserver() async throws {
        let state = AppState()
        state.status = .signedIn
        state.observeSessionInvalidation()
        let observer = try XCTUnwrap(state.sessionExpiryTask)

        await state.signOut()

        XCTAssertNil(state.sessionExpiryTask)
        XCTAssertTrue(observer.isCancelled)
        await awaitEnd(of: observer)
    }

    /// Waits for an observer task to end, bounded so one that never ends
    /// fails as a timeout rather than hanging the suite.
    private func awaitEnd(of task: Task<Void, Never>) async {
        let ended = expectation(description: "the session observer ended")
        Task {
            await task.value
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: defaultWaitTimeout)
    }
}

/// Counts the changes Observation announces for `signedOutReason`.
@MainActor
private final class ReasonWriteCounter {
    private(set) var count = 0
    private let state: AppState

    init(watching state: AppState) {
        self.state = state
        arm()
    }

    /// Tracking is one-shot, so each change re-arms it. The callback runs
    /// synchronously inside the write, which here is always on the main actor.
    private func arm() {
        withObservationTracking {
            _ = state.signedOutReason
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.count += 1
                self?.arm()
            }
        }
    }
}
