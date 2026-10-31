import CoreGraphics
import SwiftUI
import XCTest
@testable import CabalmailUI

/// `ComposeLaptopArrangement`, what the compose form reads of the fold, the
/// keyboard and its scroll: when it is in laptop pose, where its bars go,
/// and when it samples the rest the body's height is worked out from. The
/// rules themselves are pinned in `ComposeLaptopPolicyTests`.
@MainActor
final class ComposeLaptopArrangementTests: XCTestCase {
    private let crease = CGRect(x: 0, y: 455.5, width: 669, height: 40)
    private let stacked = FoldPieces.stacked(
        top: CGRect(x: 0, y: 0, width: 653, height: 290), bottom: CGRect(x: 0, y: 330, width: 653, height: 375)
    )
    private let keyboard = CGRect(x: 0, y: 455.5, width: 669, height: 495.5)

    private func arrangement(now: @escaping () -> TimeInterval = { 0 }) -> ComposeLaptopArrangement {
        ComposeLaptopArrangement(now: now, confirmDelay: .milliseconds(5))
    }

    private func inLaptop(_ laptop: ComposeLaptopArrangement) {
        laptop.foldChanged(.horizontal(crease: crease))
        laptop.piecesChanged(stacked)
    }

    /// The window's fold alone isn't laptop pose: the sheet's own bounds
    /// have to be split across it.
    func testLaptopNeedsTheFoldAndTheSheetSplitAcrossIt() {
        let laptop = arrangement()
        laptop.foldChanged(.horizontal(crease: crease))
        XCTAssertFalse(laptop.isLaptop)

        laptop.piecesChanged(stacked)
        XCTAssertTrue(laptop.isLaptop)
        XCTAssertEqual(laptop.sections.first, .message)

        laptop.piecesChanged(.whole(CGRect(x: 0, y: 0, width: 653, height: 705)))
        XCTAssertFalse(laptop.isLaptop)
        XCTAssertEqual(laptop.sections, ComposeFormSection.allCases)
    }

    /// Book pose's vertical fold is no laptop.
    func testAVerticalFoldIsNotLaptop() {
        let laptop = arrangement()
        laptop.foldChanged(.vertical(crease: CGRect(x: 455.5, y: 0, width: 40, height: 669)))
        laptop.piecesChanged(stacked)
        XCTAssertFalse(laptop.isLaptop)
        XCTAssertEqual(laptop.host, .navigationBar)
    }

    func testTheKeyboardMovesTheBarsBetweenBottomAndTop() {
        let laptop = arrangement()
        inLaptop(laptop)
        XCTAssertEqual(laptop.host, .laptopBottom)
        XCTAssertTrue(laptop.barsBelowFold)

        laptop.keyboardChanged(keyboard)
        XCTAssertEqual(laptop.host, .laptopTop)
        XCTAssertNil(laptop.toastFloor)

        laptop.keyboardChanged(nil)
        XCTAssertEqual(laptop.host, .laptopBottom)
        XCTAssertEqual(laptop.toastFloor, 495.5)
    }

    func testAKeyboardWithNoFoldLeavesTodaysBar() {
        let laptop = arrangement()
        laptop.keyboardChanged(keyboard)
        XCTAssertEqual(laptop.host, .navigationBar)
        XCTAssertEqual(laptop.bodyFrame, .natural)
    }

    /// At the top, idle, with the keyboard down: the body's height follows
    /// from the frames, once they have held.
    func testRestIsSampledAtTheTopAndSetsTheBodysHeight() async throws {
        let laptop = arrangement()
        inLaptop(laptop)
        laptop.scrollPhase(.idle)
        laptop.scrolled(fromRest: 0)
        laptop.bodyMoved(CGRect(x: 44, y: 219.5, width: 581, height: 240))
        laptop.fieldsMoved(top: 492)

        try await waitUntilOnMainActor { laptop.rest != nil }
        XCTAssertEqual(laptop.rest, .init(bodyTop: 219.5, gap: 32.5))
        XCTAssertEqual(laptop.bodyFrame, .init(height: 221, bridge: 22.5))
    }

    func testNothingIsSampledWhileScrolledOrTyping() async throws {
        let laptop = arrangement()
        inLaptop(laptop)
        laptop.bodyMoved(CGRect(x: 44, y: 219.5, width: 581, height: 240))
        laptop.fieldsMoved(top: 492)
        laptop.scrolled(fromRest: 40)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(laptop.rest, "scrolled 40 pt")

        laptop.scrolled(fromRest: 0)
        laptop.keyboardChanged(keyboard)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(laptop.rest, "the keyboard is up")

        laptop.keyboardChanged(nil)
        laptop.scrollPhase(.interacting)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(laptop.rest, "the user is scrolling")
    }

    /// The rest survives a keyboard-up period and goes with laptop pose.
    func testRestOutlivesTypingAndEndsWithLaptop() async throws {
        let laptop = arrangement()
        inLaptop(laptop)
        laptop.bodyMoved(CGRect(x: 44, y: 219.5, width: 581, height: 240))
        laptop.fieldsMoved(top: 492)
        try await waitUntilOnMainActor { laptop.rest != nil }
        let frame = laptop.bodyFrame

        laptop.keyboardChanged(keyboard)
        laptop.bodyMoved(CGRect(x: 44, y: 60, width: 581, height: 150))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(laptop.bodyFrame, frame)

        laptop.foldChanged(.none)
        XCTAssertNil(laptop.rest)
        XCTAssertEqual(laptop.bodyFrame, .natural)
    }

    func testEditMessageAndTheUsersScrollAreCounted() {
        var clock: TimeInterval = 10
        let laptop = arrangement(now: { clock })
        XCTAssertNil(laptop.secondsSinceUserScroll)

        laptop.scrollPhase(.interacting)
        clock = 10.4
        XCTAssertEqual(laptop.secondsSinceUserScroll ?? 0, 0.4, accuracy: 0.001)
        XCTAssertTrue(laptop.isScrolling)

        laptop.requestEdit()
        laptop.requestEdit()
        XCTAssertEqual(laptop.editRequests, 2)
    }
}
