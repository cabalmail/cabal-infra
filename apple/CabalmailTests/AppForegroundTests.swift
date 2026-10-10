import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// What the app does as it leaves and returns to the foreground
/// (`AppState.appScenePhaseChanged(to:)`), once for the app: each app
/// entry's scene-level handler calls it with the app's own phase, where
/// every main window's root used to answer the one change. And the
/// cross-device probe, which stays with the windows but asks the server
/// once for windows that come forward together.
@MainActor
final class AppForegroundTests: XCTestCase {
    private var harness: SessionHarness!
    private var preferences: Preferences!

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
        preferences = Preferences(store: InMemoryPreferenceStore())
        harness.appState.usePreferences(preferences)
        await SignOutSuiteSteps.signIn(harness)
        // The session's own first pull of the preferences.
        try await waitUntilOnMainActor { self.preferences.onLocalChange != nil }
    }

    override func tearDown() async throws {
        await harness.tearDown()
        harness = nil
        preferences = nil
        try await super.tearDown()
    }

    private func calls(_ path: String) async -> Int {
        await harness.cognito.trail.filter { $0 == "API GET /prod/\(path)" }.count
    }

    /// The resume session is written at once, inside its save's debounce,
    /// so a termination while backgrounded does not lose it.
    func testLeavingTheForegroundWritesTheResumeSessionNow() throws {
        let coordinator = try XCTUnwrap(harness.appState.navCoordinator)
        let store = ResumeSessionStore(defaults: harness.defaults)
        coordinator.recordFolder("Archive")
        XCTAssertNotEqual(store.loadSession()?.folder, "Archive", "precondition: the save is still debounced")

        harness.appState.appScenePhaseChanged(to: .inactive)

        XCTAssertEqual(store.loadSession()?.folder, "Archive")
    }

    func testReturningToTheForegroundReconcilesThePreferencesOnce() async throws {
        let before = await calls("get_preferences")

        harness.appState.appScenePhaseChanged(to: .active)

        let cognito = harness.cognito
        try await waitUntil {
            await cognito.trail.filter { $0 == "API GET /prod/get_preferences" }.count == before + 1
        }
        try await Task.sleep(for: .milliseconds(200))
        let after = await calls("get_preferences")
        XCTAssertEqual(after, before + 1, "one change, one pull")
    }

    /// On the way out the app only writes: nothing is asked of the server.
    func testLeavingTheForegroundAsksTheServerNothing() async throws {
        let before = await harness.cognito.trail

        harness.appState.appScenePhaseChanged(to: .inactive)
        harness.appState.appScenePhaseChanged(to: .background)
        try await Task.sleep(for: .milliseconds(200))

        let after = await harness.cognito.trail
        XCTAssertEqual(after, before)
    }

    /// Two main windows come to the front together, and each asks for the
    /// cross-device offer: the server is asked once.
    func testWindowsComingForwardTogetherAskForTheCrossDeviceOfferOnce() async throws {
        let appState = harness.appState
        let before = await calls("get_nav_state")

        async let first: Void = appState.offerCrossDeviceCursor(atLaunch: false)
        async let second: Void = appState.offerCrossDeviceCursor(atLaunch: false)
        _ = await (first, second)

        let after = await calls("get_nav_state")
        XCTAssertEqual(after, before + 1)
        XCTAssertNil(appState.toast, "the unscripted answer holds no cursor to offer")

        // One after the other, each asks: the guard is for probes in flight.
        await appState.offerCrossDeviceCursor(atLaunch: false)
        let later = await calls("get_nav_state")
        XCTAssertEqual(later, before + 2)
    }
}
