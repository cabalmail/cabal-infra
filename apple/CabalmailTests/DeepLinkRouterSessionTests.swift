import XCTest
import CabalmailKit
@testable import CabalmailUI

/// `DeepLinkRouter` across a session's ends: a link that arrives while a
/// session ends parks rather than open in a window about to close, no
/// window of the ending session takes it, and whether the sign-out drops
/// it turns on whether it arrived before the sign-out forgot the account.
@MainActor
final class DeepLinkRouterSessionTests: XCTestCase {
    private var harness: SessionHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
        harness.seedLastSession()
        try await harness.seedTokens()
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let archiveSeven = DeepLink.message(NavState(folder: "Archive", uid: 7, clientID: "push"))

    /// A main window of the harness's session, registered with its router.
    private func window() throws -> SceneNavigator {
        let appState = harness.appState
        let navigator = SceneNavigator(
            coordinator: { appState.navCoordinator }, hasClient: { true }, seed: .mail, deepLinks: appState.deepLinks
        )
        navigator.windowID = UUID()
        appState.deepLinks.register(navigator)
        return navigator
    }

    /// A sign-out is waiting on the launch restore when a link arrives: it
    /// parks rather than open, and the sign-out, which has yet to forget the
    /// account, drops it.
    func testALinkParkedBeforeASignOutForgetsTheAccountGoesWithIt() async throws {
        let appState = harness.appState
        let router = appState.deepLinks
        let navigator = try window()
        harness.holdNextConfigurationLoad()
        let restore = Task { await appState.restoreIfPossible() }
        await harness.awaitConfigurationLoad()
        let signOut = Task { await appState.signOut() }
        try await waitUntilOnMainActor { appState.sessionManager.teardownGate.isTearingDown }

        router.open(archiveSeven, in: navigator.windowID)

        XCTAssertNil(navigator.selectedFolder, "not into a window while the session ends")
        XCTAssertEqual(router.parked, archiveSeven)
        harness.releaseConfigurationLoad()
        await restore.value
        await signOut.value
        XCTAssertNil(router.parked, "the sign-out drops it")
    }

    /// A link that arrives once the sign-out has forgotten the account,
    /// while its teardown still waits on the network, is the next session's,
    /// as one that arrives after the sign-out is. No window of the ending
    /// session takes it, landing or opening; the same account's first window
    /// does. (Another account's sign-in drops it: `PushAccountSwitchTests`.)
    func testALinkArrivingLateInASignOutWaitsForTheNextSession() async throws {
        let appState = harness.appState
        let router = appState.deepLinks
        await appState.restoreIfPossible()
        let navigator = try window()
        let hook = HeldHook()
        appState.sessionManager.sessionEnvironment.hooks.sessionWillEnd = { await hook.hold() }
        let signOut = Task { await appState.signOut() }
        await hook.arrived()

        router.open(archiveSeven, in: navigator.windowID)
        await navigator.mailTreeAppeared(UUID(), isWide: false)
        let late = try window()

        XCTAssertNotEqual(navigator.selectedFolder?.path, "Archive", "not into a window landing meanwhile")
        XCTAssertNil(late.selectedFolder, "nor one opening meanwhile")
        XCTAssertEqual(router.parked, archiveSeven)
        hook.release()
        await signOut.value
        XCTAssertEqual(router.parked, archiveSeven, "kept for the next session")

        harness.seedLastSession()
        try await harness.seedTokens()
        await appState.restoreIfPossible()
        let next = try window()
        XCTAssertNil(router.parked)
        XCTAssertEqual(next.selectedFolder?.path, "Archive")
    }

    /// The Mac opens a main window for a link that parks while a session is
    /// wired (every main window closed); never during a launch, when the
    /// first window is on its way, and never while a window can take it.
    func testAMainWindowOpensOnlyForALinkParkedInAWiredSession() async throws {
        let opened = Counter()
        let unwired = AppState()
        unwired.deepLinks.opensMainWindow = { opened.count += 1 }
        unwired.deepLinks.open(archiveSeven)
        XCTAssertEqual(opened.count, 0, "no session: the launch opens its own window")

        await harness.appState.restoreIfPossible()
        let router = harness.appState.deepLinks
        router.opensMainWindow = { opened.count += 1 }
        router.open(archiveSeven)
        XCTAssertEqual(opened.count, 1)

        let navigator = try window()
        router.open(.folder("Junk"))
        XCTAssertEqual(opened.count, 1, "a window took it")
        XCTAssertEqual(navigator.selectedFolder?.path, "Junk")
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    /// A session hook that parks until released, once, and reports its
    /// arrival.
    @MainActor
    private final class HeldHook {
        private var held: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?
        private var hasArrived = false
        private var isReleased = false

        func hold() async {
            guard !isReleased else { return }
            hasArrived = true
            waiter?.resume()
            waiter = nil
            await withCheckedContinuation { held = $0 }
        }

        func arrived() async {
            if hasArrived { return }
            await withCheckedContinuation { waiter = $0 }
        }

        func release() {
            isReleased = true
            held?.resume()
            held = nil
        }
    }
}
