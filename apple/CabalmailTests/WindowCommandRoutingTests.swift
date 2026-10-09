import XCTest
import SwiftUI
@testable import CabalmailUI

/// Workstream 3.1's window commands from the gear, ⌘, and the feed catalog,
/// hosted offscreen like `WindowCommandDeliveryTests`: Settings opens in its
/// own window only, and the feed catalog's one handler a window answers from
/// a tab that is not in front, as it did before the commands moved.
@MainActor
final class WindowCommandRoutingTests: XCTestCase {

    @Observable
    @MainActor
    fileprivate final class Probe {
        var answers: [String] = []
    }

    private func makeWindow(wide: Bool, tab: CompactTab = .mail) -> WindowCommands {
        let navigator = SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: .mail)
        navigator.layoutIsWide = wide
        navigator.showTab(tab)
        return WindowCommands(navigator: navigator)
    }

    /// The gear and ⌘, send Settings to their own window's object: that
    /// window opens Settings, and no other one does.
    func testASettingsRequestReachesOnlyItsOwnWindow() async throws {
        let windowA = makeWindow(wide: true)
        let windowB = makeWindow(wide: true)
        let probe = Probe()
        let harness = HostedViewHarness {
            VStack {
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.settings) { probe.answers.append("A") }
                    .environment(\.windowCommands, windowA)
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.settings) { probe.answers.append("B") }
                    .environment(\.windowCommands, windowB)
            }
        }
        defer { harness.close() }
        try await harness.settle()

        windowB.send(.settings)
        _ = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()

        XCTAssertEqual(probe.answers, ["B"], "Settings opens in window B only")
    }

    /// The Feeds menu's catalog commands have one handler a window, the feed
    /// sidebar's `FeedManagementSheets`, which answers from a tab behind (as
    /// it did before 3.1); a host that does not handle commands never does.
    func testTheFeedCatalogHandlerAnswersFromATabBehind() async throws {
        let window = makeWindow(wide: false, tab: .mail)
        let probe = Probe()
        let harness = HostedViewHarness {
            VStack {
                Color.clear.frame(width: 10, height: 10)
                    .feedManagementSheets(FeedManagementActions(), management: nil, folders: [],
                                          selection: .constant(nil), handlesCommands: true,
                                          onRefresh: { probe.answers.append("sidebar") })
                Color.clear.frame(width: 10, height: 10)
                    .feedManagementSheets(FeedManagementActions(), management: nil, folders: [],
                                          selection: .constant(nil), onRefresh: { probe.answers.append("list") })
            }
            .environment(\.commandTab, .feeds)
            .environment(\.windowCommands, window)
        }
        defer { harness.close() }
        try await harness.settle()

        window.send(.feed(.refresh))
        _ = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()

        XCTAssertEqual(probe.answers, ["sidebar"], "the Feeds tab is behind the Mail tab, and still answers")
    }
}
