import XCTest
import CabalmailKit
@testable import CabalmailUI

/// When the session lifecycle runs the cache root's launch step
/// (`docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.2). The step keeps the
/// remembered account's saved mail and removes everybody else's, so it has
/// to run once per process, before the first client is built, whichever
/// path builds it: a window's restore, a sign-in, or a notification action
/// or App Intent on a background launch. And it is told the account the
/// install remembers, never the one being typed.
@MainActor
final class SessionStorageLaunchTests: XCTestCase {
    private var harness: SessionHarness!
    private static let alice = "prepare cabalmail.example alice"

    override func setUp() async throws {
        harness = try SessionHarness()
    }

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
    }

    // MARK: - Who runs it

    func testARestoreRunsTheLaunchStepBeforeItBuildsItsClient() async throws {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await harness.seedTokens()

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.storageTrail, [Self.alice, "makeClient"])
    }

    /// A background launch has no window, so no restore: the client lent to
    /// a notification action is the first one built. The restore that
    /// follows when a window opens adopts it, and the step is not run again.
    func testABackgroundLaunchsBorrowRunsTheLaunchStepBeforeItBuildsTheLentClient() async throws {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await harness.seedTokens()

        let lent = try await harness.appState.sessionManager.borrowClient()

        XCTAssertNotNil(lent)
        XCTAssertEqual(harness.storageTrail, [Self.alice, "makeClient"])

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.storageTrail, [Self.alice, "makeClient"], "once per process")
    }

    /// Nobody signed in and nobody remembered: no client is built, and the
    /// launch still tidies the cache root.
    func testALaunchWithNobodyRememberedRunsTheLaunchStepForNoAccount() async {
        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.storageTrail, ["prepare none"])
        XCTAssertNil(harness.appState.client)
    }

    /// Signed out by choice: the pair is remembered and there are no
    /// tokens, so no client is built. The step still runs, which is what
    /// removes a directory a failed sign-out removal left.
    func testALaunchSignedOutRunsTheLaunchStepForTheRememberedAccount() async {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.storageTrail, [Self.alice])
    }

    /// The stored session turns out to have expired. The step ran for the
    /// remembered account, which keeps its directory, and nothing after the
    /// refusal runs it again or forgets the account.
    func testALaunchWhoseSessionHasExpiredRanTheLaunchStepForTheRememberedAccount() async throws {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        try await harness.seedTokens(expiresIn: -60)
        await harness.cognito.script(.refresh, .error(type: "NotAuthorizedException", message: "revoked"))

        await harness.appState.restoreIfPossible()

        XCTAssertEqual(harness.appState.status, .signedOut)
        XCTAssertEqual(harness.storageTrail, [Self.alice, "makeClient"])
        XCTAssertEqual(harness.defaults.string(forKey: "cabalmail.lastUsername"), "alice")
    }

    // MARK: - Whose account

    /// A sign-in can be the first thing to build a client. The step is the
    /// launch's all the same: it keeps the remembered account's mail, not
    /// the typed one's, because the sign-in may still be refused.
    func testASignInAsAnotherAccountRunsTheLaunchStepForTheRememberedOne() async {
        harness.seedLastSession(controlDomain: "cabalmail.example", username: "alice")
        await harness.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))

        await harness.appState.signIn(
            controlDomain: SignInScript.domain, username: "bob", password: SignInScript.password
        )

        XCTAssertNotEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.storageTrail, [Self.alice, "makeClient"])
    }

    func testASecondSignInDoesNotRunTheLaunchStepAgain() async {
        await harness.cognito.script(.passwordSignIn, .error(type: "NotAuthorizedException"))
        await harness.cognito.script(.passwordSignIn, .tokens(id: "ID-1"))

        for _ in 1...2 {
            await harness.appState.signIn(
                controlDomain: SignInScript.domain, username: "alice", password: SignInScript.password
            )
        }

        XCTAssertEqual(harness.appState.status, .signedIn)
        XCTAssertEqual(harness.storageTrail, ["prepare none", "makeClient", "makeClient"])
    }

    // MARK: - Once, with whoever asks meanwhile waiting

    /// A window's restore and a background borrow can both ask while the
    /// step runs. The second waits for the first's run rather than building
    /// a client over a root that is still being tidied.
    func testWhoeverAsksWhileTheStepRunsWaitsForItAndItRunsOnce() async {
        let step = LaunchStorageStep()
        let probe = HeldStep()

        let first = Task { @MainActor in
            await step.run { await probe.run() }
            probe.order.append("first continues")
        }
        await probe.awaitArrival()
        let second = Task { @MainActor in
            await step.run { await probe.run() }
            probe.order.append("second continues")
        }
        // Long enough for the second to have gone ahead, were it not waiting.
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.order, [], "the second caller went ahead while the step ran")

        probe.release()
        await first.value
        await second.value

        XCTAssertEqual(probe.runs, 1)
        XCTAssertEqual(probe.order.first, "step finished")
        XCTAssertEqual(Set(probe.order.dropFirst()), ["first continues", "second continues"])

        await step.run { await probe.run() }
        XCTAssertEqual(probe.runs, 1, "and it is free from then on")
    }
}

/// A launch step that stays in flight until the test lets it finish.
@MainActor
private final class HeldStep {
    private(set) var runs = 0
    var order: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    private var arrived: CheckedContinuation<Void, Never>?

    func run() async {
        runs += 1
        await withCheckedContinuation { continuation in
            held = continuation
            arrived?.resume()
            arrived = nil
        }
        order.append("step finished")
    }

    /// Returns once the step is in flight.
    func awaitArrival() async {
        guard held == nil else { return }
        await withCheckedContinuation { arrived = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
