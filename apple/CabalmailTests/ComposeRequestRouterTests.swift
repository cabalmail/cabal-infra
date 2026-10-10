import XCTest
import SwiftUI
import CabalmailKit
@testable import CabalmailUI

/// A main window's compose surface (`ComposeRequestRouter`), hosted so its
/// task and `onDisappear` run: it registers with the coordinator under its
/// window's identity while it is mounted, and takes no seed while its window
/// has no session. The app state here is signed out, so the surface refuses
/// everything and nothing opens on screen.
@MainActor
final class ComposeRequestRouterTests: XCTestCase {
    /// Whether the window shows its signed-in root, which carries the
    /// router: a sign-out takes it out of the hierarchy.
    @Observable
    @MainActor
    final class Window {
        var showsSignedInRoot = true
    }

    private struct Host: View {
        let window: Window
        let windowID: UUID
        let appState: AppState
        let preferences: Preferences

        var body: some View {
            Group {
                if window.showsSignedInRoot {
                    Color.clear.composeRequestRouter()
                } else {
                    Color.clear
                }
            }
            .environment(\.commandWindowID, windowID)
            .environment(appState)
            .environment(preferences)
        }
    }

    func testTheRouterIsItsWindowsSurfaceWhileMounted() async throws {
        let appState = AppState()
        let window = Window()
        let windowID = UUID()
        // Registered first: a request naming no window goes to the surface
        // registered last, so this one is shown it only while no router is.
        let outside = RecordingComposeSurface(window: nil).register(with: appState.compose)
        let host = HostedViewHarness {
            Host(
                window: window, windowID: windowID, appState: appState,
                preferences: Preferences(store: InMemoryPreferenceStore())
            )
        }
        defer { host.close() }
        try await host.settle()

        let refused = Draft(subject: "while mounted")
        appState.compose.open(seed: refused, from: nil)
        XCTAssertEqual(outside.shown, [], "the router's surface was asked, not the one before it")
        XCTAssertEqual(
            appState.compose.seedsWaiting(for: windowID), [refused],
            "with no session it takes nothing, and the request waits for its window"
        )

        window.showsSignedInRoot = false
        let handedOn = try await host.eventually { outside.shown == [refused] }
        XCTAssertTrue(handedOn, "the router's surface went with its view, and its request went to the one left")
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowID), [])
        let later = Draft(subject: "after it went")
        appState.compose.open(seed: later, from: nil)
        XCTAssertEqual(outside.shown, [refused, later])
    }
}
