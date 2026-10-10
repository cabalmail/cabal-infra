import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal, ported by workstream 3.1 (#1824). The menu commands that were
/// `AppState` ticks aimed through one shared target slot are now each main
/// window's own (`WindowCommands`): every row below is the check it was, on
/// the window's command object, so a command reaches its own window's
/// surfaces, once, and no other's. Compose left the last tick and the shared
/// target slot in workstream 3.3 (`ComposeCoordinator`): its rows are the
/// checks they were, on what the coordinator shows and keeps waiting, except
/// the three the tick's defects were pinned by (a compose aimed at no window
/// reaching every window, the one shared target slot, and a view outside
/// any main window answering every compose), which pin what replaced them.
/// The drag-move tick beside them is as it was.
@MainActor
final class CommandTickCharacterizationTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    /// The tick still on `AppState`: the drag move, which no command bumps.
    private func ticks(_ state: AppState) -> [String: Int] {
        ["move": state.moveRequestTick]
    }

    private func makeWindow() -> WindowCommands {
        WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
    }

    /// `window`'s compose sheet is up, so a compose for it waits for it: the
    /// request the rows below check stays where it was aimed.
    private func sheetUp(in window: UUID, of appState: AppState) {
        RecordingComposeSurface(window: window, isSheet: true).register(with: appState.compose).isBusy = true
    }

    // MARK: - T1: one count per command

    func testTheTableCoversEveryWindowCommandFromZero() {
        XCTAssertEqual(Self.everyWindowCommand.count, 21, "nine commands, eight feed and four tree")
        XCTAssertEqual(Set(Self.everyWindowCommand).count, 21, "each listed once")
        let window = makeWindow()
        XCTAssertTrue(Self.everyWindowCommand.allSatisfy { window.count(of: $0) == 0 }, "every count starts at zero")
        XCTAssertTrue(ticks(AppState()).values.allSatisfy { $0 == 0 })
    }

    func testEachCommandBumpsOnlyItsOwnCountByExactlyOne() {
        for command in Self.everyWindowCommand {
            let window = makeWindow()
            window.send(command)
            let moved = Self.everyWindowCommand.filter { window.count(of: $0) != 0 }
            XCTAssertEqual(moved, [command], "\(command): its own count +1, every other count unchanged")
            XCTAssertEqual(window.count(of: command), 1)
            // A repeat still bumps, which is what makes `.onChange` fire again.
            window.send(command)
            XCTAssertEqual(window.count(of: command), 2, "\(command): a repeat bumps again")
        }
        // A compose request is no tick at all.
        let appState = AppState()
        appState.compose.open(seed: Draft(subject: "seeded"), from: windowA)
        appState.compose.open(seed: Draft(subject: "seeded"), from: windowA)
        XCTAssertTrue(ticks(appState).values.allSatisfy { $0 == 0 })
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil).count, 2, "a repeat is a second request")
    }

    /// No command posts a mail event or a drag request: the reader and the
    /// composer post those, never a menu.
    func testNoCommandPostsAListEvent() {
        for command in Self.everyWindowCommand {
            let appState = AppState()
            let events = MailEventRecorder(appState.mailStore)
            makeWindow().send(command)
            XCTAssertNil(appState.pendingMoveRequest, "\(command)")
            XCTAssertEqual(events.events, [], "\(command)")
        }
        let appState = AppState()
        let events = MailEventRecorder(appState.mailStore)
        let surface = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        appState.compose.open(seed: Draft(subject: "seeded"), from: windowA)
        XCTAssertEqual(surface.shown.count, 1, "precondition: the compose was shown")
        XCTAssertNil(appState.pendingMoveRequest, "a compose request")
        XCTAssertEqual(events.events, [], "a compose request")
    }

    func testACommandSentToOneWindowReachesOnlyThatWindow() {
        for command in Self.everyWindowCommand {
            let windowA = makeWindow()
            let windowB = makeWindow()
            windowA.send(command)
            XCTAssertEqual(windowA.count(of: command), 1, "\(command) reaches the window it was sent to")
            XCTAssertEqual(windowB.count(of: command), 0, "\(command) must not reach a second window")
        }
        // A compose request: the surface of the window it names, and no
        // other. A surface outside any main window (a preview, a test) is
        // not shown a request another window's surface takes; on the tick it
        // answered every request, beside the window that was named.
        let appState = AppState()
        let seed = Draft(subject: "seeded")
        let outside = RecordingComposeSurface(window: nil).register(with: appState.compose)
        let surfaceA = RecordingComposeSurface(window: windowA).register(with: appState.compose)
        let surfaceB = RecordingComposeSurface(window: windowB).register(with: appState.compose)
        appState.compose.open(seed: seed, from: windowA)
        XCTAssertEqual(surfaceA.shown, [seed], "a compose reaches the window it names")
        XCTAssertEqual(surfaceB.shown, [], "a compose must not reach a second window")
        XCTAssertEqual(outside.shown, [], "nor a surface outside any window")
    }

    /// Fixed in #1824, with `CommandHandoffCharacterizationTests`' mailto
    /// row: a compose aimed at no window reached every window's router, and
    /// each opened a composer. It opens in one window now, the one opened
    /// last, however an earlier request was aimed.
    func testAComposeAimedAtNoWindowReachesOneWindow() {
        let windowC = UUID()
        let appState = AppState()
        let surfaces = [windowA, windowB, windowC].map {
            RecordingComposeSurface(window: $0).register(with: appState.compose)
        }
        // Aimed elsewhere first, so a request that reused an earlier one's
        // window cannot pass.
        appState.compose.open(seed: Draft(subject: "earlier"), from: windowA)
        let seed = Draft(subject: "no window")

        appState.compose.open(seed: seed, from: nil)

        XCTAssertEqual(surfaces.filter { $0.shown.contains(seed) }.map(\.window), [windowC])
    }

    // MARK: - T1: what rides with a command

    /// A compose with no surface to show it (signed out, or no window
    /// mounted yet) waits for one. (The zero-argument form this row also
    /// pinned, which parked nothing and left a seed in place, had no callers
    /// and went with the tick.)
    func testAComposeWithNoSurfaceWaits() {
        let appState = AppState()
        let seed = Draft(to: ["someone@cabalmail.example"], subject: "From a mailto link")

        appState.compose.open(seed: seed, from: windowA)

        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [seed])
    }

    func testEveryFeedCommandIsItsOwnCommand() {
        let window = makeWindow()
        for command in Self.everyFeedCommand {
            window.send(.feed(command))
            XCTAssertEqual(window.count(of: .feed(command)), 1, "\(command)")
        }
        window.send(.feed(.markAllRead))
        XCTAssertEqual(window.count(of: .feed(.markAllRead)), 2, "the same command twice still bumps")
        XCTAssertEqual(Self.everyFeedCommand.filter { window.count(of: .feed($0)) == 1 }.count, 7, "the rest unchanged")
    }

    func testEverySidebarTreeCommandIsItsOwnCommand() {
        let window = makeWindow()
        for command in Self.everySidebarTreeCommand {
            window.send(.sidebarTree(command))
            XCTAssertEqual(window.count(of: .sidebarTree(command)), 1, "\(command)")
            // Both sidebars answer the four; each applies only its own
            // tree's commands (`FolderListView`, `FeedSidebarSection`).
            switch command {
            case .expandAllFolders, .collapseAllFolders: XCTAssertTrue(command.isMail, "\(command)")
            case .expandAllFeedFolders, .collapseAllFeedFolders: XCTAssertFalse(command.isMail, "\(command)")
            }
            switch command {
            case .collapseAllFolders, .collapseAllFeedFolders: XCTAssertTrue(command.collapses, "\(command)")
            case .expandAllFolders, .expandAllFeedFolders: XCTAssertFalse(command.collapses, "\(command)")
            }
        }
    }

    /// The feed and tree commands name their action in their case, so there
    /// is no payload slot for a later command to overwrite before an earlier
    /// one is answered: what the shared `pendingFeedCommand` and
    /// `pendingSidebarTreeCommand` slots were pinned for, retired on purpose.
    /// No window command touches a compose seed waiting for its window.
    func testALaterCommandNeverReplacesAnEarlierOnesAction() {
        let appState = AppState()
        let seed = Draft(subject: "parked")
        sheetUp(in: windowA, of: appState)
        appState.compose.open(seed: seed, from: windowA)
        let window = makeWindow()
        window.send(.feed(.subscribe))
        window.send(.sidebarTree(.collapseAllFolders))
        let earlier: [WindowCommand] = [.feed(.subscribe), .sidebarTree(.collapseAllFolders)]
        for command in Self.everyWindowCommand where !earlier.contains(command) {
            window.send(command)
        }

        XCTAssertEqual(window.count(of: .feed(.subscribe)), 1, "a later, different command leaves it")
        XCTAssertEqual(window.count(of: .sidebarTree(.collapseAllFolders)), 1)
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowA), [seed], "no window command touches the parked seed")
    }

    func testIdenticalDragMovesStillCompareUnequalAndLeaveTheWindowTargetAlone() throws {
        let list = UUID()
        let items = [MessageDragItem(uid: 7, sourceFolder: "INBOX")]
        let appState = AppState()
        let compose = Draft(subject: "waiting")
        sheetUp(in: windowA, of: appState)
        appState.compose.open(seed: compose, from: windowA)

        appState.requestMove(items: items, to: "Archive", from: list)
        let first = try XCTUnwrap(appState.pendingMoveRequest)
        appState.requestMove(items: items, to: "Archive", from: list)
        let second = try XCTUnwrap(appState.pendingMoveRequest)

        XCTAssertNotEqual(first, second, "the tick is what makes a repeated drop fire `.onChange` again")
        XCTAssertEqual(first.tick, 1)
        XCTAssertEqual(second.tick, 2)
        XCTAssertEqual(appState.moveRequestTick, second.tick)
        XCTAssertEqual(second.destination, "Archive")
        XCTAssertEqual(second.items, items)
        XCTAssertEqual(second.sourceList, list)
        // A drag is scoped to its source list, not a window: the compose
        // request's target survives it.
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowA), [compose])
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowB), [])
    }

    // MARK: - T2: no shared target slot

    /// The target was one slot every compose request overwrote, read when
    /// an observer ran, so the last writer decided who an undelivered
    /// request reached. Each waiting request keeps its own window now: a
    /// later one, aimed anywhere or nowhere, moves none before it. (The one
    /// aimed nowhere waits for whichever surface can show it first.)
    func testALaterComposeNeverRetargetsAnEarlierOne() {
        let state = AppState()
        sheetUp(in: windowB, of: state)
        sheetUp(in: windowA, of: state)
        let first = Draft(subject: "first")
        let second = Draft(subject: "second")
        let third = Draft(subject: "third")
        state.compose.open(seed: first, from: windowB)
        state.compose.open(seed: second, from: windowA)
        state.compose.open(seed: third, from: nil)

        XCTAssertEqual(state.compose.seedsWaiting(for: windowB), [first])
        XCTAssertEqual(state.compose.seedsWaiting(for: windowA), [second])
        XCTAssertEqual(state.compose.seedsWaiting(for: nil), [third])
    }

    /// #1824's main path, fixed: a data-change reload sent after an aimed
    /// request, before SwiftUI has delivered it, leaves that request aimed
    /// where it was. The reload senders run from async continuations on the
    /// main actor -- `FolderMarkAllRead.perform`,
    /// `FolderListViewModel.emptyTrash` and `PushRegistrar`'s notification
    /// actions after their server call -- so any of them can land between a
    /// request and the next update. They used to send an untargeted
    /// refresh, which re-aimed the request at every window; they now bump
    /// the mail store's own counter, and a compose request is no longer on
    /// a shared slot to be re-aimed.
    /// `CommandHandoffCharacterizationTests` drives the first two end to end.
    func testADataChangeReloadLeavesAWaitingComposeWithItsWindow() {
        let appState = AppState()
        let seed = Draft(subject: "waiting")
        sheetUp(in: windowA, of: appState)
        appState.compose.open(seed: seed, from: windowA)

        appState.mailStore.requestListRefresh()

        XCTAssertEqual(appState.compose.seedsWaiting(for: windowA), [seed], "only A's surface is shown A's compose")
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowB), [])
        XCTAssertEqual(appState.compose.seedsWaiting(for: nil), [])
        XCTAssertEqual(appState.mailStore.listRefreshTick, 1)
    }

    /// #1824's second quirk, fixed: two commands sent in one update to two
    /// windows each reach their own. On the shared target slot window A's
    /// reader dropped its own Reply and B's answered it; the Message menu now
    /// sends to the front window's own `WindowCommands`, one count a command.
    func testTwoCommandsInOneUpdateEachReachTheirOwnWindow() {
        let commandsA = WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
        let commandsB = WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
        commandsA.send(.reply)
        commandsB.send(.toggleSeen)

        XCTAssertEqual(commandsA.count(of: .reply), 1, "A's own Reply reaches A")
        XCTAssertEqual(commandsB.count(of: .reply), 0, "and not B")
        XCTAssertEqual(commandsB.count(of: .toggleSeen), 1)
        XCTAssertEqual(commandsA.count(of: .toggleSeen), 0)
    }

    /// The window registry (`lastActiveMainWindow`) and a waiting compose's
    /// window are separate: bringing a window to the front or closing one
    /// does not re-aim a request already made.
    func testNotingOrForgettingAWindowLeavesAWaitingComposeWithItsWindow() {
        let appState = AppState()
        let seed = Draft(subject: "waiting")
        sheetUp(in: windowA, of: appState)
        appState.compose.open(seed: seed, from: windowA)

        appState.noteActiveMainWindow(windowB)
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowB), [])
        XCTAssertEqual(appState.lastActiveMainWindow, windowB)

        appState.forgetMainWindow(windowB)
        appState.forgetMainWindow(windowA)
        XCTAssertEqual(
            appState.compose.seedsWaiting(for: windowA), [seed], "its request stays until its surface goes"
        )
        XCTAssertEqual(appState.compose.seedsWaiting(for: windowB), [])
        XCTAssertNil(appState.lastActiveMainWindow)
    }
}

extension CommandTickCharacterizationTests {
    /// Every `FeedCommand`, also the rows of
    /// `FeedCommandReceiverCharacterizationTests`' table. `listed` switches
    /// over it with no `default`, so a new case stops this file compiling
    /// until it is listed here as well.
    static let everyFeedCommand: [FeedCommand] = [
        .subscribe, .newFolder, .importOpml, .exportOpml, .refresh, .toggleRead, .toggleFlag, .markAllRead,
    ].map(listed)

    /// Every `SidebarTreeCommand`; the switches in
    /// `testEverySidebarTreeCommandIsItsOwnCommand` are its exhaustiveness check.
    static let everySidebarTreeCommand: [SidebarTreeCommand] = [
        .expandAllFolders, .collapseAllFolders, .expandAllFeedFolders, .collapseAllFeedFolders,
    ]

    /// Every `WindowCommand`; `listedCommand` is its exhaustiveness check.
    static let everyWindowCommand: [WindowCommand] = ([
        .reply, .replyAll, .forward, .toggleSeen, .toggleFlagged, .moveSelection, .refresh, .markFolderRead, .settings,
    ] as [WindowCommand]).map(listedCommand)
        + everyFeedCommand.map(WindowCommand.feed) + everySidebarTreeCommand.map(WindowCommand.sidebarTree)

    nonisolated private static func listedCommand(_ command: WindowCommand) -> WindowCommand {
        switch command {
        case .reply, .replyAll, .forward, .toggleSeen, .toggleFlagged, .moveSelection: command
        case .refresh, .markFolderRead, .settings, .feed, .sidebarTree: command
        }
    }

    nonisolated private static func listed(_ command: FeedCommand) -> FeedCommand {
        switch command {
        case .subscribe, .newFolder, .importOpml, .exportOpml, .refresh: command
        case .toggleRead, .toggleFlag, .markAllRead: command
        }
    }
}
