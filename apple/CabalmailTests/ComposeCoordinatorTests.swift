import XCTest
import CabalmailKit
@testable import CabalmailUI

/// Where a compose request goes (`ComposeCoordinator`): the compose surface
/// of the one main window it names, or one window when it names none, and
/// never two. A request no surface can show yet waits, in order, for its
/// window: through a sign-out, behind an open sheet, or before any window
/// exists. (`CommandHandoffCharacterizationTests` holds the rows ported from
/// the compose tick, the two fixed #1824 defects among them.)
@MainActor
final class ComposeCoordinatorTests: XCTestCase {
    private let windowA = UUID()
    private let windowB = UUID()
    private var coordinator: ComposeCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        coordinator = AppState().compose
    }

    private func surface(_ window: UUID?, isSheet: Bool = false) -> RecordingComposeSurface {
        RecordingComposeSurface(window: window, isSheet: isSheet).register(with: coordinator)
    }

    // MARK: Which window

    /// Two iPad windows and a request from one: one composer.
    func testARequestOpensOnlyInTheWindowItCameFrom() {
        let surfaceA = surface(windowA)
        let surfaceB = surface(windowB)
        let seed = Draft(subject: "reply")

        coordinator.open(seed: seed, from: windowA)

        XCTAssertEqual(surfaceA.shown, [seed])
        XCTAssertEqual(surfaceB.shown, [])
    }

    /// A cold launch from a mailto: link: no window exists yet. The first
    /// surface to register opens it, and one that registers after is shown
    /// nothing.
    func testARequestBeforeAnyWindowWaitsForTheFirstSurface() {
        let seed = Draft(subject: "mailto")
        coordinator.open(seed: seed, from: nil)
        XCTAssertEqual(coordinator.seedsWaiting(for: nil), [seed])

        let first = surface(windowA)
        let second = surface(windowB)

        XCTAssertEqual(first.shown, [seed])
        XCTAssertEqual(second.shown, [])
        XCTAssertEqual(coordinator.seedsWaiting(for: nil), [])
    }

    /// A mailto: while signed out, aimed at the window last used: another
    /// window that is signed in does not open it, and the window it was for
    /// does once it has signed in.
    func testARequestForAWindowWithNoSurfaceWaitsForThatWindow() {
        let surfaceB = surface(windowB)
        let seed = Draft(subject: "mailto")

        coordinator.open(seed: seed, from: windowA)
        XCTAssertEqual(surfaceB.shown, [], "not in another window")
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [seed])

        let surfaceA = surface(windowA)
        XCTAssertEqual(surfaceA.shown, [seed])
        XCTAssertEqual(surfaceB.shown, [])
    }

    // MARK: Waiting

    /// The session ends with a request waiting behind a sheet: the window's
    /// surface goes with the session, the request is kept, and the window's
    /// surface in the next session opens it.
    func testAWaitingRequestIsKeptThroughASignOut() {
        let sheet = surface(windowA, isSheet: true)
        let typing = Draft(subject: "being typed")
        let seed = Draft(subject: "mailto")
        coordinator.open(seed: typing, from: windowA)
        coordinator.open(seed: seed, from: windowA)

        sheet.unregister(from: coordinator)
        coordinator.presenterIsFree()
        XCTAssertEqual(sheet.shown, [typing], "a surface that has gone is shown nothing")
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [seed])

        let next = surface(windowA, isSheet: true)
        XCTAssertEqual(next.shown, [seed])
    }

    /// The sheet has closed but has not said so yet, and another request
    /// arrives: the one that was waiting goes first.
    func testAnOlderRequestGoesFirstWhenANewOneArrives() {
        let sheet = surface(windowA, isSheet: true)
        let typing = Draft(subject: "being typed")
        let older = Draft(subject: "older")
        let newer = Draft(subject: "newer")
        coordinator.open(seed: typing, from: windowA)
        coordinator.open(seed: older, from: windowA)
        sheet.isBusy = false

        coordinator.open(seed: newer, from: windowA)

        XCTAssertEqual(sheet.shown, [typing, older])
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [newer])
    }

    /// A request that named no window, offered to a window whose sheet is
    /// up, is that window's from then on: a window opened meanwhile does
    /// not take it, so it cannot open in two.
    func testARequestAWindowCouldNotShowYetStaysThatWindows() {
        let sheet = surface(windowA, isSheet: true)
        let typing = Draft(subject: "being typed")
        let seed = Draft(subject: "mailto")
        coordinator.open(seed: typing, from: windowA)

        coordinator.open(seed: seed, from: nil)
        XCTAssertEqual(coordinator.seedsWaiting(for: nil), [])
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [seed])

        let later = surface(windowB)
        XCTAssertEqual(later.shown, [], "a window opened meanwhile leaves it")
        sheet.free(in: coordinator)
        XCTAssertEqual(sheet.shown, [typing, seed])
    }

    /// One window's sheet being up holds back only that window's requests.
    func testABusyWindowDoesNotHoldBackAnother() {
        let sheet = surface(windowA, isSheet: true)
        let other = surface(windowB)
        let typing = Draft(subject: "being typed")
        let forA = Draft(subject: "for A")
        let forB = Draft(subject: "for B")
        coordinator.open(seed: typing, from: windowA)
        coordinator.open(seed: forA, from: windowA)

        coordinator.open(seed: forB, from: windowB)

        XCTAssertEqual(other.shown, [forB])
        XCTAssertEqual(sheet.shown, [typing])
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [forA])
    }

    /// A surface that asks for another composer while it is showing one
    /// (a compose opened from a compose) is shown each exactly once.
    func testARequestMadeWhileShowingAnotherIsShownOnce() {
        let showing = surface(windowA)
        let first = Draft(subject: "first")
        let second = Draft(subject: "second")
        showing.whileShowing = { [coordinator, windowA] seed in
            if seed == first { coordinator?.open(seed: second, from: windowA) }
        }

        coordinator.open(seed: first, from: windowA)

        XCTAssertEqual(showing.shown, [first, second])
        XCTAssertEqual(coordinator.seedsWaiting(for: windowA), [])
    }

    /// A surface that could not show a request and frees up a moment later
    /// is not shown a newer one first.
    func testARequestIsNotShownAheadOfAnOlderOneForItsWindow() {
        let older = Draft(subject: "older")
        let newer = Draft(subject: "newer")
        coordinator.open(seed: older, from: windowA)
        coordinator.open(seed: newer, from: windowA)
        let late = RecordingComposeSurface(window: windowA)
        late.refusals = 1

        late.register(with: coordinator)
        XCTAssertEqual(late.shown, [], "the newer one waits behind the one refused")

        coordinator.presenterIsFree()
        XCTAssertEqual(late.shown, [older, newer])
    }

    /// Another window's surface comes up while one is being offered a
    /// request it cannot show: the requests waiting for the new surface
    /// open, without waiting for something else to ask.
    func testASurfaceThatRegistersDuringAnOfferGetsItsRequests() {
        let windowC = UUID()
        let forA = Draft(subject: "for A")
        let forB = Draft(subject: "for B")
        let forC = Draft(subject: "for C")
        coordinator.open(seed: forA, from: windowA)
        coordinator.open(seed: forB, from: windowB)
        let surfaceA = RecordingComposeSurface(window: windowA)
        let surfaceB = RecordingComposeSurface(window: windowB)
        let busy = RecordingComposeSurface(window: windowC, isSheet: true)
        busy.isBusy = true
        busy.register(with: coordinator)
        busy.whileOffered = { [coordinator] _ in
            guard surfaceA.shown.isEmpty, let coordinator else { return }
            surfaceA.register(with: coordinator)
            surfaceB.register(with: coordinator)
        }

        coordinator.open(seed: forC, from: windowC)

        XCTAssertEqual(surfaceA.shown, [forA])
        XCTAssertEqual(surfaceB.shown, [forB])
        XCTAssertEqual(busy.shown, [])
        XCTAssertEqual(coordinator.seedsWaiting(for: windowC), [forC])
    }

    // MARK: Compose windows

    /// The coordinator hands out the slots the compose scene reads back
    /// (`AppState.composeSlots`), not a registry of its own.
    func testTheCoordinatorUsesTheAppsSlotRegistry() {
        let appState = AppState()

        XCTAssertTrue(appState.compose.slots === appState.composeSlots)
    }

    /// A compose window remembers the main window it was opened from, which
    /// closing it returns to, for as long as it holds its slot.
    func testAComposeWindowKnowsTheWindowItCameFrom() {
        let seed = Draft(subject: "reply")

        let slot = coordinator.slot(for: seed, from: windowA)

        XCTAssertEqual(coordinator.slots.seed(for: slot), seed)
        XCTAssertEqual(coordinator.origin(of: slot), windowA)
        XCTAssertNil(coordinator.origin(of: nil), "a restored or system-spawned window has no slot")
    }

    /// The Mac's File ▸ New Message and menu-bar item open a compose scene
    /// with every main window closed (#1162): no surface is asked, and the
    /// window has none to return to, even on a slot another window left.
    func testTheMacMenuPathOpensAWindowWithoutAskingASurface() throws {
        let shown = surface(windowA)
        let earlier = coordinator.slot(for: Draft(subject: "earlier"), from: windowA)
        coordinator.slots.release(earlier)
        let seed = Draft()
        var opened: ComposeSlot?

        coordinator.openNewWindow(seed: seed) { opened = $0 }

        let slot = try XCTUnwrap(opened)
        XCTAssertEqual(slot, earlier, "precondition: the slot is recycled")
        XCTAssertEqual(coordinator.slots.seed(for: slot), seed)
        XCTAssertNil(coordinator.origin(of: slot))
        XCTAssertEqual(shown.shown, [])
        XCTAssertEqual(coordinator.seedsWaiting(for: nil), [])
    }
}
