import XCTest
import SwiftUI
@testable import CabalmailUI

/// The window commands as SwiftUI delivers them (`answersCommand`, the
/// availability reporters), hosted offscreen: a command reaches its own
/// window's surface exactly once, only the tab in front answers, and a
/// surface's report is read while its tab is in front and withdrawn when it
/// goes.
@MainActor
final class WindowCommandDeliveryTests: XCTestCase {

    @Observable
    @MainActor
    fileprivate final class Probe {
        var answers: [String] = []
        var mounted = true
        var current: WindowCommands?
    }

    private func makeWindow(wide: Bool, tab: CompactTab = .mail) -> WindowCommands {
        let navigator = SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: .mail)
        navigator.layoutIsWide = wide
        navigator.showTab(tab)
        return WindowCommands(navigator: navigator)
    }

    func testACommandReachesItsOwnWindowsSurfaceExactlyOnce() async throws {
        let windowA = makeWindow(wide: true)
        let windowB = makeWindow(wide: true)
        let probe = Probe()
        let harness = HostedViewHarness {
            VStack {
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.reply) { probe.answers.append("A") }
                    .environment(\.windowCommands, windowA)
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.reply) { probe.answers.append("B") }
                    .environment(\.windowCommands, windowB)
            }
        }
        defer { harness.close() }
        try await harness.settle()

        windowA.send(.reply)
        let answered = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()

        XCTAssertTrue(answered)
        XCTAssertEqual(probe.answers, ["A"], "once, in window A only")

        windowB.send(.reply)
        windowB.send(.toggleSeen)
        _ = try await harness.eventually { probe.answers.count > 1 }
        try await harness.settle()
        XCTAssertEqual(probe.answers, ["A", "B"])
    }

    func testOnlyTheTabInFrontAnswers() async throws {
        let window = makeWindow(wide: false, tab: .mail)
        let probe = Probe()
        let harness = HostedViewHarness {
            VStack {
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.toggleSeen) { probe.answers.append("mail") }
                    .environment(\.commandTab, .mail)
                Color.clear.frame(width: 10, height: 10)
                    .answersCommand(.toggleSeen) { probe.answers.append("search") }
                    .environment(\.commandTab, .search)
            }
            .environment(\.windowCommands, window)
        }
        defer { harness.close() }
        try await harness.settle()

        window.send(.toggleSeen)
        _ = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()
        XCTAssertEqual(probe.answers, ["mail"], "the Search tab is mounted but behind")

        window.navigator.showTab(.search)
        window.send(.toggleSeen)
        _ = try await harness.eventually { probe.answers.count > 1 }
        try await harness.settle()
        XCTAssertEqual(probe.answers, ["mail", "search"])
    }

    /// A window's one handler for a command (the feed catalog, a sidebar
    /// tree) answers from a tab that is not in front.
    func testAHandlerThatAnswersWhileBehindStillAnswers() async throws {
        let window = makeWindow(wide: false, tab: .search)
        let probe = Probe()
        let harness = HostedViewHarness {
            Color.clear.frame(width: 10, height: 10)
                .answersCommands([.feed(.subscribe), .sidebarTree(.expandAllFolders)], whileBehind: true) { command in
                    probe.answers.append("\(command)")
                }
                .environment(\.commandTab, .feeds)
                .environment(\.windowCommands, window)
        }
        defer { harness.close() }
        try await harness.settle()

        window.send(.sidebarTree(.expandAllFolders))
        _ = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()

        XCTAssertEqual(probe.answers, ["\(WindowCommand.sidebarTree(.expandAllFolders))"], "only the command sent")
    }

    /// The window's object is rebuilt for a new sign-in; the change of
    /// object is not a command, even when the new one's count is higher.
    func testANewWindowObjectIsNotACommand() async throws {
        let old = makeWindow(wide: true)
        let new = makeWindow(wide: true)
        new.send(.reply)
        new.send(.reply)
        let probe = Probe()
        probe.current = old
        let harness = HostedViewHarness { SwappedWindowProbe(probe: probe) }
        defer { harness.close() }
        try await harness.settle()

        probe.current = new
        try await harness.settle()
        XCTAssertEqual(probe.answers, [])

        new.send(.reply)
        _ = try await harness.eventually { !probe.answers.isEmpty }
        try await harness.settle()
        XCTAssertEqual(probe.answers, ["reply"])
    }

    func testASurfacesReportIsReadWhileItsTabIsInFrontAndWithdrawnWhenItGoes() async throws {
        let window = makeWindow(wide: false, tab: .search)
        let probe = Probe()
        let harness = HostedViewHarness { MountedReporterProbe(probe: probe, window: window) }
        defer { harness.close() }

        let reported = try await harness.eventually { window.messageMenu.selectedCount == 2 }
        XCTAssertTrue(reported)
        XCTAssertTrue(window.mailbox.canRefresh, "a mail surface is on screen")
        window.navigator.showTab(.mail)
        XCTAssertEqual(window.messageMenu, MessageMenuAvailability.none, "another tab in front reads its own report")
        window.navigator.showTab(.search)

        probe.mounted = false
        let withdrawn = try await harness.eventually { window.messageMenu == MessageMenuAvailability.none }
        XCTAssertTrue(withdrawn)
        XCTAssertFalse(window.mailbox.canRefresh)
    }
}

/// Reads the probe's window in its body, so swapping it re-renders.
private struct SwappedWindowProbe: View {
    let probe: WindowCommandDeliveryTests.Probe

    var body: some View {
        Color.clear.frame(width: 10, height: 10)
            .answersCommand(.reply) { probe.answers.append("reply") }
            .environment(\.windowCommands, probe.current)
    }
}

/// A Search tab surface reporting a two-message selection while the probe
/// keeps it mounted.
private struct MountedReporterProbe: View {
    let probe: WindowCommandDeliveryTests.Probe
    let window: WindowCommands

    var body: some View {
        if probe.mounted {
            Color.clear.frame(width: 10, height: 10)
                .reportsMessageMenuAvailability(selectedCount: 2, hasOpenMessage: false)
                .environment(\.commandTab, .search)
                .environment(\.windowCommands, window)
        }
    }
}
