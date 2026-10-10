import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// What a main window writes to its scene storage, and when
/// (`WindowPlaceKeeper`), hosted so its `onChange`s run: the route as it
/// changes, and the folder list's place with each route and as the scene
/// leaves the foreground, never as the list scrolls.
@MainActor
final class WindowPlaceKeeperTests: XCTestCase {
    /// The window's scene storage and scene phase, as the test sets them.
    @Observable
    @MainActor
    final class Scene {
        var stored: Data?
        var phase = ScenePhase.active
    }

    private struct Host: View {
        @Bindable var scene: Scene
        let navigator: SceneNavigator
        let appState: AppState

        var body: some View {
            Color.clear
                .modifier(WindowPlaceKeeper(navigator: navigator, storedRoute: $scene.stored))
                .environment(\.scenePhase, scene.phase)
                .environment(appState)
        }
    }

    private var harness: SessionHarness!
    private var scene: Scene!
    private var navigator: SceneNavigator!
    private var host: HostedViewHarness!
    private var tree = UUID()

    override func setUp() async throws {
        try await super.setUp()
        harness = try SessionHarness()
        harness.seedLastSession()
        try await harness.seedTokens()
        await harness.appState.restoreIfPossible()
        XCTAssertEqual(harness.appState.status, .signedIn, "precondition")
        scene = Scene()
        try await mount(SceneNavigator(appState: harness.appState, windowID: UUID()))
    }

    /// Hosts `window`'s keeper and lands the window.
    private func mount(_ window: SceneNavigator) async throws {
        host?.close()
        navigator = window
        host = HostedViewHarness { [scene, harness] in
            Host(scene: scene!, navigator: window, appState: harness!.appState)
        }
        try await host.settle()
        await navigator.mailTreeAppeared(tree, isWide: false)
    }

    override func tearDown() async throws {
        host.close()
        host = nil
        navigator = nil
        scene = nil
        await harness.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private var stored: StoredRoute? {
        StoredRoute.stored(in: scene.stored, for: harness.appState.routeAccount)
    }

    private func place(_ index: Int) throws -> ListAnchor {
        try XCTUnwrap(ListAnchor(
            folderPath: "INBOX", messageID: "<row\(index)@example.com>", uid: UInt32(5000 - index), index: index
        ))
    }

    /// The window's list scrolls to `index`.
    private func scrollList(to index: Int) throws {
        let list = navigator.listHold.claim("INBOX")
        XCTAssertTrue(navigator.listHold.record(try place(index), under: list))
    }

    func testTheLandingsRouteIsStoredWithNoPlace() async throws {
        let landed = try await host.eventually { self.stored?.route.mail.folderPath == "INBOX" }

        XCTAssertTrue(landed)
        XCTAssertNil(stored?.listAnchor)
    }

    /// Each write re-renders the window's root, so a scroll writes nothing;
    /// the place goes in when the scene leaves the foreground.
    func testAScrollWritesNothingUntilTheSceneLeavesTheForeground() async throws {
        _ = try await host.eventually { self.stored != nil }
        let before = scene.stored

        try scrollList(to: 300)
        try await host.settle()
        XCTAssertEqual(scene.stored, before, "never per scroll")

        scene.phase = .inactive
        let wrote = try await host.eventually { self.stored?.listAnchor != nil }
        XCTAssertTrue(wrote)
        XCTAssertEqual(stored?.listPlace, try place(300))
        XCTAssertEqual(stored?.route.mail.folderPath, "INBOX")
    }

    func testARouteChangeStoresThePlaceTheListHasReached() async throws {
        _ = try await host.eventually { self.stored != nil }
        try scrollList(to: 300)

        let message = TestFixtures.makeEnvelope(uid: 9, messageId: "<nine@example.com>")
        navigator.selectMessage(message, isSearching: false, from: tree)

        let wrote = try await host.eventually { self.stored?.route.mail.message?.uid == 9 }
        XCTAssertTrue(wrote)
        XCTAssertEqual(stored?.listPlace, try place(300))
    }

    /// A restored window's place is only parked until its list lands. What
    /// the window stores meanwhile (its landing's route, the scene leaving
    /// the foreground during a slow first load) keeps that place.
    func testARestoredWindowsPlaceIsKeptUntilItsListLands() async throws {
        var route = AppRoute(section: .mail)
        route.mail = AppRoute.Mail(folderPath: "INBOX")
        let restored = StoredRoute(account: harness.appState.routeAccount, route: route, listAnchor: try place(300))
        scene.stored = nil
        try await mount(SceneNavigator(appState: harness.appState, windowID: UUID(), stored: restored))

        let landed = try await host.eventually { self.stored?.route.mail.folderPath == "INBOX" }
        XCTAssertTrue(landed)
        XCTAssertEqual(stored?.listPlace, try place(300), "the landing's route kept it")

        scene.phase = .inactive
        try await host.settle()
        XCTAssertEqual(stored?.listPlace, try place(300), "and so did leaving the foreground")
    }

    /// Which window was last used is stored with each, as it changes.
    func testTheWindowLastUsedIsStoredAsItChanges() async throws {
        _ = try await host.eventually { self.stored != nil }
        let window = try XCTUnwrap(navigator.windowID)

        harness.appState.noteActiveMainWindow(window)
        let becameLastUsed = try await host.eventually { self.stored?.wasLastUsed == true }
        XCTAssertTrue(becameLastUsed)

        harness.appState.noteActiveMainWindow(UUID())
        let gaveWay = try await host.eventually { self.stored?.wasLastUsed == false }
        XCTAssertTrue(gaveWay)
    }

    /// Leaving the foreground with nothing new to store writes nothing.
    func testLeavingTheForegroundWithNothingNewWritesNothing() async throws {
        _ = try await host.eventually { self.stored != nil }
        scene.phase = .inactive
        try await host.settle()
        let before = scene.stored
        scene.stored = before.map { $0 + Data(" ".utf8) }
        let padded = scene.stored

        scene.phase = .background
        try await host.settle()

        XCTAssertEqual(scene.stored, padded, "the same place is not written again")
    }
}
