import XCTest
import CabalmailKit
@testable import Cabalmail

/// Characterization suite for workstream 0.8 of the 2026-10 rearchitecture
/// proposal: the `AppState` command-tick contract as it stands after its
/// defect 11, window-scoped menu commands (#1783, d8b58f48, merged as
/// 5caaec3a). Workstream 3.1 replaces these integer ticks with
/// focused-window commands; this file is the 1:1 contract that replacement
/// has to match, quirks included, so any change in behaviour shows up as a
/// failing assertion rather than a silent drift.
///
/// It covers every one of the 13 `request…` entry points (12 window-aimed
/// ticks), the drag-move tick beside them, and the single shared target slot
/// the observers read when a tick fires. `CommandWindowTargetingTests` pins
/// the targeting rules on 6 of the entry points; this table overlaps it
/// where it needs those rows, then runs the same contract over all 13.
@MainActor
final class CommandTickCharacterizationTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()

    /// Every command tick on `AppState`, keyed by a short name. `move` is the
    /// drag-move tick: no `request…(in:)` entry point bumps it, so every row
    /// below must leave it alone.
    private func ticks(_ state: AppState) -> [String: Int] {
        [
            "compose": state.composeRequestTick,
            "refresh": state.refreshRequestTick,
            "reply": state.replyRequestTick,
            "replyAll": state.replyAllRequestTick,
            "forward": state.forwardRequestTick,
            "toggleSeen": state.toggleSeenRequestTick,
            "toggleFlagged": state.toggleFlaggedRequestTick,
            "moveSelection": state.moveSelectionRequestTick,
            "markFolderRead": state.markFolderReadRequestTick,
            "settings": state.settingsRequestTick,
            "feed": state.feedCommandTick,
            "sidebarTree": state.sidebarTreeCommandTick,
            "move": state.moveRequestTick,
        ]
    }

    /// The 13 entry points the menus, toolbars and handlers call today.
    private var entryPoints: [CommandEntryPoint] {
        [
            CommandEntryPoint(name: "requestCompose(in:)", tick: "compose") { $0.requestCompose(in: $1) },
            CommandEntryPoint(name: "requestCompose(seed:in:)", tick: "compose") {
                $0.requestCompose(seed: Draft(subject: "seeded"), in: $1)
            },
            CommandEntryPoint(name: "requestRefresh(in:)", tick: "refresh") { $0.requestRefresh(in: $1) },
            CommandEntryPoint(name: "requestReply(in:)", tick: "reply") { $0.requestReply(in: $1) },
            CommandEntryPoint(name: "requestReplyAll(in:)", tick: "replyAll") { $0.requestReplyAll(in: $1) },
            CommandEntryPoint(name: "requestForward(in:)", tick: "forward") { $0.requestForward(in: $1) },
            CommandEntryPoint(name: "requestToggleSeen(in:)", tick: "toggleSeen") { $0.requestToggleSeen(in: $1) },
            CommandEntryPoint(name: "requestToggleFlagged(in:)", tick: "toggleFlagged") {
                $0.requestToggleFlagged(in: $1)
            },
            CommandEntryPoint(name: "requestMoveSelection(in:)", tick: "moveSelection") {
                $0.requestMoveSelection(in: $1)
            },
            CommandEntryPoint(name: "requestMarkFolderRead(in:)", tick: "markFolderRead") {
                $0.requestMarkFolderRead(in: $1)
            },
            CommandEntryPoint(name: "requestSettings(in:)", tick: "settings") { $0.requestSettings(in: $1) },
            CommandEntryPoint(name: "requestFeedCommand(_:in:)", tick: "feed") {
                $0.requestFeedCommand(.subscribe, in: $1)
            },
            CommandEntryPoint(name: "requestSidebarTree(_:in:)", tick: "sidebarTree") {
                $0.requestSidebarTree(.collapseAllFolders, in: $1)
            },
        ]
    }

    // MARK: - T1: one tick per entry point

    func testTheTableCoversEveryWindowAimedTickFromZero() {
        let entries = entryPoints
        XCTAssertEqual(entries.count, 13, "13 request entry points today")
        let fresh = ticks(AppState())
        XCTAssertTrue(fresh.values.allSatisfy { $0 == 0 }, "every tick starts at zero: \(fresh)")
        XCTAssertEqual(
            Set(entries.map(\.tick)), Set(fresh.keys).subtracting(["move"]),
            "the 12 window-aimed ticks each have at least one entry point; the drag tick has none"
        )
    }

    func testEachEntryPointBumpsOnlyItsOwnTickByExactlyOne() {
        for entry in entryPoints {
            let appState = AppState()
            var expected = ticks(appState)

            entry.request(appState, windowA)
            expected[entry.tick, default: 0] += 1
            XCTAssertEqual(ticks(appState), expected, "\(entry.name): its own tick +1, every other tick unchanged")

            // A repeat of the same command still bumps, which is what makes
            // `.onChange` fire again for it.
            entry.request(appState, windowA)
            expected[entry.tick, default: 0] += 1
            XCTAssertEqual(ticks(appState), expected, "\(entry.name): a repeat bumps again")
        }
    }

    func testNoEntryPointPostsAListSignal() {
        for entry in entryPoints {
            let appState = AppState()
            entry.request(appState, windowA)
            XCTAssertNil(appState.pendingMoveRequest, entry.name)
            XCTAssertNil(appState.lastDisposedEnvelope, entry.name)
            XCTAssertNil(appState.lastFailedRemoval, entry.name)
            XCTAssertNil(appState.lastEnvelopeFlagChange, entry.name)
            XCTAssertNil(appState.lastReadAdvanceRequest, entry.name)
            XCTAssertNil(appState.lastDraftReplaced, entry.name)
            XCTAssertEqual(appState.failedRemovalTick, 0, entry.name)
        }
    }

    func testAnEntryPointAimedAtOneWindowReachesOnlyThatWindow() {
        for entry in entryPoints {
            let appState = AppState()
            entry.request(appState, windowA)
            XCTAssertTrue(appState.commandReaches(windowA), "\(entry.name) reaches the window it names")
            XCTAssertFalse(appState.commandReaches(windowB), "\(entry.name) must not reach a second window")
            XCTAssertTrue(appState.commandReaches(nil), "\(entry.name): a view outside a main window still answers")
        }
    }

    func testAnEntryPointAimedAtNoWindowReachesEveryWindow() {
        let windowC = UUID()
        for entry in entryPoints {
            let appState = AppState()
            // Aimed elsewhere first, so a request that skipped the target
            // write (a fresh slot is already nil) cannot pass.
            appState.requestSettings(in: windowC)
            XCTAssertFalse(appState.commandReaches(windowA), "precondition for \(entry.name)")

            entry.request(appState, nil)
            XCTAssertTrue(appState.commandReaches(windowA), entry.name)
            XCTAssertTrue(appState.commandReaches(windowB), entry.name)
            XCTAssertTrue(appState.commandReaches(windowC), entry.name)
        }
    }

    // MARK: - T1: the payloads that ride beside a tick

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

    func testEveryFeedCommandIsNamedBesideItsTick() {
        let appState = AppState()
        for (index, command) in Self.everyFeedCommand.enumerated() {
            appState.requestFeedCommand(command, in: windowA)
            XCTAssertEqual(appState.pendingFeedCommand, command)
            XCTAssertEqual(appState.feedCommandTick, index + 1)
        }
        appState.requestFeedCommand(.markAllRead, in: windowA)
        XCTAssertEqual(appState.feedCommandTick, Self.everyFeedCommand.count + 1, "the same command twice still bumps")
    }

    func testEverySidebarTreeCommandIsNamedBesideItsTick() {
        let appState = AppState()
        for (index, command) in Self.everySidebarTreeCommand.enumerated() {
            appState.requestSidebarTree(command, in: nil)
            XCTAssertEqual(appState.pendingSidebarTreeCommand, command)
            XCTAssertEqual(appState.sidebarTreeCommandTick, index + 1)
            // Both sidebars observe the one tick; each applies only its own
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

    /// The named payloads are never cleared: each stays until the next
    /// request of its own kind replaces it, and only
    /// `consumePendingComposeSeed()` takes the parked seed
    /// (`CommandHandoffCharacterizationTests`). Harmless today, since every
    /// reader of the feed and tree commands runs inside the matching tick's
    /// `.onWindowCommand` (`FeedManagementSheets`, `FeedItemListView`,
    /// `FolderListView`, `FeedSidebarSection`); pinned so workstream 3.1
    /// drops these slots deliberately rather than by accident.
    func testTheNamedPayloadsOutliveEveryLaterDifferentTick() {
        let appState = AppState()
        let seed = Draft(subject: "parked")
        appState.requestCompose(seed: seed, in: windowA)
        appState.requestFeedCommand(.subscribe, in: windowA)
        appState.requestSidebarTree(.collapseAllFolders, in: windowA)
        for entry in entryPoints where !["compose", "feed", "sidebarTree"].contains(entry.tick) {
            entry.request(appState, windowB)
        }

        XCTAssertEqual(appState.pendingFeedCommand, .subscribe, "a later, different tick leaves it")
        XCTAssertEqual(appState.pendingSidebarTreeCommand, .collapseAllFolders)
        XCTAssertEqual(appState.pendingComposeSeed, seed)

        appState.requestFeedCommand(.refresh, in: windowB)
        XCTAssertEqual(appState.pendingSidebarTreeCommand, .collapseAllFolders, "a feed command leaves the tree's")
        appState.requestSidebarTree(.expandAllFeedFolders, in: windowB)
        XCTAssertEqual(appState.pendingFeedCommand, .refresh, "a tree command leaves the feed's")
        XCTAssertEqual(appState.pendingComposeSeed, seed, "neither touches the parked seed")
    }

    func testIdenticalDragMovesStillCompareUnequalAndLeaveTheWindowTargetAlone() throws {
        let list = UUID()
        let items = [MessageDragItem(uid: 7, sourceFolder: "INBOX")]
        let appState = AppState()
        appState.requestReply(in: windowA)

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
        // A drag is scoped to its source list, not a window: the reply's
        // target survives it.
        XCTAssertFalse(appState.commandReaches(windowB))
        XCTAssertEqual(appState.replyRequestTick, 1)
    }

    // MARK: - T2: one shared target slot

    /// The target is read when an observer runs, not stored with the tick
    /// (`MainWindowCommandScope.swift`, `WindowCommandObserver`). Each entry
    /// point overwrites the one slot, so the last writer decides who a tick
    /// that has not been delivered yet reaches.
    func testTheTargetIsOneSharedSlotAndTheLastWriterWins() {
        for entry in entryPoints {
            let state = AppState()
            state.requestReply(in: windowB)
            entry.request(state, windowA)
            XCTAssertFalse(state.commandReaches(windowB), "\(entry.name) replaces an earlier window target")
            entry.request(state, nil)
            XCTAssertTrue(state.commandReaches(windowB), "\(entry.name) with no window clears it")
        }
    }

    /// Pins current behaviour, which looks like a defect: an untargeted
    /// refresh sent after an aimed command, before SwiftUI has delivered it,
    /// re-aims that command at every window, so every window's reader answers
    /// the one Reply (defect 11 back again: two replies, two toggles). The
    /// untargeted senders run from async continuations on the main actor --
    /// `FolderMarkAllRead.perform`, `FolderListViewModel.emptyTrash` and
    /// `PushRegistrar`'s notification actions after their server call -- so
    /// any of them can land between a menu command's bump and the next
    /// update. `CommandHandoffCharacterizationTests` drives the first two
    /// end to end.
    /// Tracked in #1824.
    func testAnUntargetedRefreshBeforeDeliveryReAimsAnEarlierAimedTickAtEveryWindow() {
        let appState = AppState()
        appState.requestReply(in: windowA)
        XCTAssertFalse(appState.commandReaches(windowB))

        appState.requestRefresh()

        XCTAssertTrue(appState.commandReaches(windowA))
        XCTAssertTrue(appState.commandReaches(windowB), "B's reader would answer A's Reply too")
        XCTAssertEqual(appState.replyRequestTick, 1)
        XCTAssertEqual(appState.refreshRequestTick, 1)
    }

    /// Pins current behaviour, which looks like a defect (latent; no call
    /// site does this today): two aimed requests in one update leave the
    /// first tick aimed at the second request's window, so window A's reader
    /// drops its own Reply and window B's answers it.
    /// Tracked in #1824.
    func testTwoAimedRequestsInOneUpdateAimBothTicksAtTheSecondWindow() {
        let appState = AppState()
        appState.requestReply(in: windowA)
        appState.requestToggleSeen(in: windowB)

        XCTAssertFalse(appState.commandReaches(windowA), "A's own Reply would be dropped")
        XCTAssertTrue(appState.commandReaches(windowB))
        XCTAssertEqual(appState.replyRequestTick, 1)
        XCTAssertEqual(appState.toggleSeenRequestTick, 1)
    }

    /// The window registry (`lastActiveMainWindow`) and the target slot are
    /// separate: bringing a window to the front or closing one does not
    /// re-aim a tick already bumped.
    func testNotingOrForgettingAWindowLeavesTheCommandTargetAlone() {
        let appState = AppState()
        appState.requestReply(in: windowA)

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
    /// `FeedCommandReceiverCharacterizationTests`' table. The enum is not
    /// `CaseIterable`; `listed` switches over it with no `default`, so a case
    /// added during workstream 3.1 stops this file compiling until it is
    /// listed here as well.
    static let everyFeedCommand: [FeedCommand] = [
        .subscribe, .newFolder, .importOpml, .exportOpml, .refresh, .toggleRead, .toggleFlag, .markAllRead,
    ].map(listed)

    /// Every `SidebarTreeCommand`; the switches in
    /// `testEverySidebarTreeCommandIsNamedBesideItsTick` are its exhaustiveness check.
    static let everySidebarTreeCommand: [SidebarTreeCommand] = [
        .expandAllFolders, .collapseAllFolders, .expandAllFeedFolders, .collapseAllFeedFolders,
    ]

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
