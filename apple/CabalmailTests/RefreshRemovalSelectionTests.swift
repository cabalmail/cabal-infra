import XCTest
import CabalmailKit
@testable import CabalmailUI

/// What a list's selection and its reader do when a *refresh* -- not the app
/// itself -- proves a loaded row gone from the folder (#2037).
///
/// The app's own removals go through `MailEventSelectionPolicy`, which moves
/// or clears the selection. A removal another client made used to reach only
/// `WindowRefresher.applyRefreshPage`, which pruned the row and the caches
/// and told nothing that holds the selection, so a reader on that row kept
/// rendering a message the server no longer had -- with a live toolbar whose
/// writes reached nowhere. `FolderWindowHost.windowDidRemoveRows(_:)` now
/// queues the same `.removal` reaction the app's own path queues, with no
/// target and no advance.
///
/// The shared set-up lives in `RefreshCharacterizationFixture.swift`; the
/// view's side of the reaction is applied through `ListViewSelection`, which
/// mirrors `MessageListView.applySelectionReactions`.
@MainActor
final class RefreshRemovalSelectionTests: XCTestCase {
    private var fixture: RefreshCharacterizationFixture!
    private let window = UUID()

    override func setUp() async throws {
        fixture = RefreshCharacterizationFixture()
    }

    override func tearDown() async throws {
        fixture.removeScratch()
        fixture = nil
    }

    /// The reported symptom: the row leaves the list and the reader empties.
    func testARefreshThatProvesTheOpenRowGoneEmptiesTheReader() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.selectedRefs = [fixture.ref(2)]
        let view = ListViewSelection(model, in: window)
        XCTAssertEqual(view.shown, fixture.ref(2), "the reader starts on the row another client is about to take")
        await fixture.scriptRefresh(messages: 2, page: [3, 1])

        await model.refresh()
        view.apply()

        XCTAssertEqual(model.rowRefs, [fixture.ref(3), fixture.ref(1)], "the row left the list")
        XCTAssertNil(view.shown, "and the reader let go of it")
        XCTAssertEqual(model.selectedRefs, [], "nothing stays selected")
    }

    /// The reaction's shape is the design call: a removal nobody here made
    /// advances no window, so it carries no target. Were it to advance, the
    /// reader would jump to a neighbour the user never picked.
    func testTheQueuedReactionNeitherAdvancesNorNamesATarget() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        await fixture.scriptRefresh(messages: 2, page: [3, 1])

        await model.refresh()

        XCTAssertEqual(
            model.selectionReactions.since(0),
            [ListSelectionReaction(
                kind: .removal, rows: [fixture.ref(2)], target: nil, origin: nil, advances: false
            )]
        )
    }

    /// A selection wider than the vanished row keeps its other rows, exactly
    /// as it does for a change another list made.
    func testARefreshLeavesTheRestOfAWiderSelectionSelected() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.selectedRefs = [fixture.ref(3), fixture.ref(2)]
        let view = ListViewSelection(model, in: window)
        await fixture.scriptRefresh(messages: 2, page: [3, 1])

        await model.refresh()
        view.apply()

        XCTAssertEqual(model.selectedRefs, [fixture.ref(3)])
        XCTAssertEqual(
            view.shown, fixture.ref(3),
            "and the one row left drives the reader, as it does for every other removal"
        )
    }

    /// Negative control: a row the reader is not on going away leaves the
    /// reader alone. Without it, "the reader cleared" could be the fix
    /// clearing on every refresh that prunes anything.
    func testARefreshThatRemovesAnotherRowLeavesTheReaderWhereItIs() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.selectedRefs = [fixture.ref(3)]
        let view = ListViewSelection(model, in: window)
        await fixture.scriptRefresh(messages: 2, page: [3, 1])

        await model.refresh()
        view.apply()

        XCTAssertEqual(view.shown, fixture.ref(3))
        XCTAssertEqual(model.selectedRefs, [fixture.ref(3)])
    }

    /// Negative control for a dead detector: a refresh that returns the
    /// whole window queues nothing, so a reader stays put on a plain poll.
    func testARefreshThatPrunesNothingQueuesNoReaction() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.selectedRefs = [fixture.ref(2)]
        let view = ListViewSelection(model, in: window)
        await fixture.scriptRefresh(messages: 3, page: [3, 2, 1])

        await model.refresh()
        view.apply()

        XCTAssertEqual(model.selectionReactions.since(0), [])
        XCTAssertEqual(view.shown, fixture.ref(2))
    }

    /// The app's own dispose is exempt both ways: `applyRefreshPage` leaves
    /// a row with a removal in flight alone (the fade the animation exists
    /// for), so the refresh must not also queue a reaction for it -- that
    /// path owns the selection itself.
    func testARefreshDuringTheAppsOwnRemovalQueuesNothing() async throws {
        let model = try await fixture.makeModel(loaded: [3, 2, 1], total: 3)
        model.selectedRefs = [fixture.ref(2)]
        fixture.mailStore.shields.beginRemoval([fixture.ref(2)])
        await fixture.scriptRefresh(messages: 2, page: [3, 1])

        await model.refresh()

        XCTAssertEqual(model.rowRefs, [fixture.ref(3), fixture.ref(2), fixture.ref(1)], "the fading row stays")
        XCTAssertEqual(model.selectionReactions.since(0), [])
    }
}
