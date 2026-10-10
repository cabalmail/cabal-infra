import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal, ported by workstream 3.1 (#1824). The menu commands that were
/// `AppState` ticks aimed through one shared target slot are now each main
/// window's own (`WindowCommands`): every row below is the check it was, on
/// the window's command object, so a command reaches its own window's
/// surfaces, once, and no other's. Compose keeps its tick and the shared slot
/// until workstream 3.3, so its rows are as they were, as is the drag-move
/// tick beside them.
@MainActor
final class CommandTickCharacterizationTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    /// The ticks still on `AppState`: compose, and the drag move, which no
    /// `request…(in:)` entry point bumps.
    private func ticks(_ state: AppState) -> [String: Int] {
        ["compose": state.composeRequestTick, "move": state.moveRequestTick]
    }

    /// The compose entry points, the only ones left on the shared slot.
    private var entryPoints: [CommandEntryPoint] {
        [
            CommandEntryPoint(name: "requestCompose(in:)", tick: "compose") { $0.requestCompose(in: $1) },
            CommandEntryPoint(name: "requestCompose(seed:in:)", tick: "compose") {
                $0.requestCompose(seed: Draft(subject: "seeded"), in: $1)
            },
        ]
    }

    private func makeWindow() -> WindowCommands {
        WindowCommands(navigator: SceneNavigator(coordinator: { nil }, hasClient: { false }, seed: nil))
    }

    // MARK: - T1: one count per command

    func testTheTableCoversEveryWindowCommandFromZero() {
        XCTAssertEqual(Self.everyWindowCommand.count, 21, "nine commands, eight feed and four tree")
        XCTAssertEqual(Set(Self.everyWindowCommand).count, 21, "each listed once")
        let window = makeWindow()
        XCTAssertTrue(Self.everyWindowCommand.allSatisfy { window.count(of: $0) == 0 }, "every count starts at zero")
        XCTAssertEqual(Set(entryPoints.map(\.tick)), ["compose"], "compose keeps its AppState entry points")
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
        for entry in entryPoints {
            let appState = AppState()
            var expected = ticks(appState)
            entry.request(appState, windowA)
            expected[entry.tick, default: 0] += 1
            XCTAssertEqual(ticks(appState), expected, "\(entry.name): its own tick +1, every other tick unchanged")
            entry.request(appState, windowA)
            expected[entry.tick, default: 0] += 1
            XCTAssertEqual(ticks(appState), expected, "\(entry.name): a repeat bumps again")
        }
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
        for entry in entryPoints {
            let appState = AppState()
            let events = MailEventRecorder(appState.mailStore)
            entry.request(appState, windowA)
            XCTAssertNil(appState.pendingMoveRequest, entry.name)
            XCTAssertEqual(events.events, [], entry.name)
        }
    }

    func testACommandSentToOneWindowReachesOnlyThatWindow() {
        for command in Self.everyWindowCommand {
            let windowA = makeWindow()
            let windowB = makeWindow()
            windowA.send(command)
            XCTAssertEqual(windowA.count(of: command), 1, "\(command) reaches the window it was sent to")
            XCTAssertEqual(windowB.count(of: command), 0, "\(command) must not reach a second window")
        }
        for entry in entryPoints {
            let appState = AppState()
            entry.request(appState, windowA)
            XCTAssertTrue(appState.commandReaches(windowA), "\(entry.name) reaches the window it names")
            XCTAssertFalse(appState.commandReaches(windowB), "\(entry.name) must not reach a second window")
            XCTAssertTrue(appState.commandReaches(nil), "\(entry.name): a view outside a main window still answers")
        }
    }

    func testAComposeAimedAtNoWindowReachesEveryWindow() {
        let windowC = UUID()
        for entry in entryPoints {
            let appState = AppState()
            // Aimed elsewhere first, so a request that skipped the target
            // write (a fresh slot is already nil) cannot pass.
            appState.requestCompose(in: windowC)
            XCTAssertFalse(appState.commandReaches(windowA), "precondition for \(entry.name)")

            entry.request(appState, nil)
            XCTAssertTrue(appState.commandReaches(windowA), entry.name)
            XCTAssertTrue(appState.commandReaches(windowB), entry.name)
            XCTAssertTrue(appState.commandReaches(windowC), entry.name)
        }
    }

    // MARK: - T1: what rides with a command

    func testTheSeededComposeParksItsSeedAndTheZeroArgumentFormLeavesOneInPlace() {
        let appState = AppState()
        appState.requestCompose(in: windowA)
        XCTAssertNil(appState.pendingComposeSeed, "the zero-argument form parks nothing")

        let seed = Draft(to: ["someone@cabalmail.example"], subject: "From a mailto link")
        appState.requestCompose(seed: seed, in: windowA)
        XCTAssertEqual(appState.pendingComposeSeed, seed)

        // Pins current behaviour: the zero-argument form does not clear a seed
        // already parked, so its compose would open with that seed. It has no
        // callers today (File > New Message goes to `ComposeWindowCommand`).
        appState.requestCompose(in: windowB)
        XCTAssertEqual(appState.pendingComposeSeed, seed)
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
    /// No window command touches the compose seed `AppState` still parks.
    func testALaterCommandNeverReplacesAnEarlierOnesAction() {
        let appState = AppState()
        let seed = Draft(subject: "parked")
        appState.requestCompose(seed: seed, in: windowA)
        let window = makeWindow()
        window.send(.feed(.subscribe))
        window.send(.sidebarTree(.collapseAllFolders))
        let earlier: [WindowCommand] = [.feed(.subscribe), .sidebarTree(.collapseAllFolders)]
        for command in Self.everyWindowCommand where !earlier.contains(command) {
            window.send(command)
        }

        XCTAssertEqual(window.count(of: .feed(.subscribe)), 1, "a later, different command leaves it")
        XCTAssertEqual(window.count(of: .sidebarTree(.collapseAllFolders)), 1)
        XCTAssertEqual(appState.pendingComposeSeed, seed, "no window command touches the parked seed")
    }

    func testIdenticalDragMovesStillCompareUnequalAndLeaveTheWindowTargetAlone() throws {
        let list = UUID()
        let items = [MessageDragItem(uid: 7, sourceFolder: "INBOX")]
        let appState = AppState()
        appState.requestCompose(in: windowA)

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
        XCTAssertFalse(appState.commandReaches(windowB))
        XCTAssertEqual(appState.composeRequestTick, 1)
    }

    // MARK: - T2: one shared target slot, compose's alone now

    /// The target is read when an observer runs, not stored with the tick
    /// (`MainWindowCommandScope.swift`, `WindowCommandObserver`). Each compose
    /// entry point overwrites the one slot, so the last writer decides who a
    /// tick that has not been delivered yet reaches.
    func testTheTargetIsOneSharedSlotAndTheLastWriterWins() {
        for entry in entryPoints {
            let state = AppState()
            state.requestCompose(in: windowB)
            entry.request(state, windowA)
            XCTAssertFalse(state.commandReaches(windowB), "\(entry.name) replaces an earlier window target")
            entry.request(state, nil)
            XCTAssertTrue(state.commandReaches(windowB), "\(entry.name) with no window clears it")
        }
    }

    /// #1824's main path, fixed: a data-change reload sent after an aimed
    /// request, before SwiftUI has delivered it, leaves that request aimed
    /// where it was (a compose, the one aimed tick left). The
    /// reload senders run from async continuations on the main actor --
    /// `FolderMarkAllRead.perform`, `FolderListViewModel.emptyTrash` and
    /// `PushRegistrar`'s notification actions after their server call -- so
    /// any of them can land between a menu command's bump and the next
    /// update. They used to send an untargeted refresh, which re-aimed the
    /// command at every window; they now bump the mail store's own counter.
    /// `CommandHandoffCharacterizationTests` drives the first two end to end.
    func testADataChangeReloadBeforeDeliveryLeavesAnEarlierAimedTickAlone() {
        let appState = AppState()
        appState.requestCompose(in: windowA)
        XCTAssertFalse(appState.commandReaches(windowB))

        appState.mailStore.requestListRefresh()

        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertFalse(appState.commandReaches(windowB), "only A's router answers A's compose")
        XCTAssertEqual(appState.composeRequestTick, 1)
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

    /// The window registry (`lastActiveMainWindow`) and the target slot are
    /// separate: bringing a window to the front or closing one does not
    /// re-aim a tick already bumped.
    func testNotingOrForgettingAWindowLeavesTheCommandTargetAlone() {
        let appState = AppState()
        appState.requestCompose(in: windowA)

        appState.noteActiveMainWindow(windowB)
        XCTAssertFalse(appState.commandReaches(windowB))
        XCTAssertEqual(appState.lastActiveMainWindow, windowB)

        appState.forgetMainWindow(windowB)
        appState.forgetMainWindow(windowA)
        XCTAssertTrue(appState.commandReaches(windowA), "a closed window keeps the target until the next request")
        XCTAssertFalse(appState.commandReaches(windowB))
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

/// One `AppState.request…` entry point: its name for failure messages, the
/// tick it should bump (a key of `CommandTickCharacterizationTests.ticks`),
/// and how to call it aimed at a window, or at none.
private struct CommandEntryPoint {
    let name: String
    let tick: String
    let request: @MainActor (AppState, UUID?) -> Void
}
