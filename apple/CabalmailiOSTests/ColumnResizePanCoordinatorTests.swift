#if os(iOS)
import UIKit
import XCTest
@testable import CabalmailUI

/// The recognizer-lifetime half of the column resize handle, which is the
/// case that prompted #1112: `ColumnResizePanCoordinator` is inside an
/// `#if os(macOS)` / `#else` branch, so the mac-hosted `CabalmailMacTests`
/// bundle cannot see it and #1111 shipped its fix with nothing asserting it.
/// The pure rule it drives (`ColumnResizeGesture`) is covered over there;
/// this is the UIKit side.
///
/// What matters here is that exactly one recognizer is installed on exactly
/// one window at a time. The window retains the recognizer while the
/// recognizer holds the coordinator only weakly (target *and* delegate), so
/// a stranded recognizer outlives its delegate — and with a nil delegate
/// nothing consults `shouldReceive`, which is the only thing confining it to
/// the 22pt grab band. It would then cancel horizontal drags anywhere in the
/// app.
@MainActor
final class ColumnResizePanCoordinatorTests: XCTestCase {

    private func makeWindow() -> UIWindow {
        UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func panRecognizers(on window: UIWindow) -> [UIPanGestureRecognizer] {
        (window.gestureRecognizers ?? []).compactMap { $0 as? UIPanGestureRecognizer }
    }

    /// Attaching installs the recognizer on the *window* rather than on a
    /// view of its own — a recognizer only sees touches delivered to its
    /// view's subtree, and the handle has to sit above the rows without
    /// taking anything from them.
    func testAttachingInstallsOneRecognizerDelegatedToTheCoordinator() {
        let coordinator = ColumnResizePanCoordinator()
        let window = makeWindow()

        coordinator.attach(to: window)

        let pans = panRecognizers(on: window)
        XCTAssertEqual(pans.count, 1)
        XCTAssertTrue(
            pans.first?.delegate === coordinator,
            "the delegate is what confines the recognizer to the grab band"
        )
    }

    /// The ordinary teardown route: `didMoveToWindow(nil)` on the band view
    /// routes through `attach(to: nil)`.
    func testAttachingToNilRemovesTheRecognizer() {
        let coordinator = ColumnResizePanCoordinator()
        let window = makeWindow()
        coordinator.attach(to: window)

        coordinator.attach(to: nil)

        XCTAssertTrue(panRecognizers(on: window).isEmpty)
    }

    /// A view moving between windows must not leave a recognizer behind on
    /// the old one, and must not accumulate a second on the new one.
    func testReattachingMovesTheRecognizerInsteadOfAddingASecond() {
        let coordinator = ColumnResizePanCoordinator()
        let first = makeWindow()
        let second = makeWindow()
        let system = (first.gestureRecognizers ?? []).count
        coordinator.attach(to: first)

        coordinator.attach(to: second)

        XCTAssertTrue(panRecognizers(on: first).isEmpty, "the old window must be left clean")
        XCTAssertEqual((first.gestureRecognizers ?? []).count, system, "of the reset's recognizers too")
        XCTAssertEqual(panRecognizers(on: second).count, 1)
        XCTAssertEqual((second.gestureRecognizers ?? []).count, system + 3)
    }

    /// #1111's fix, which had no suite that could reach it. The coordinator
    /// can be released before `attach(to: nil)` ever runs, because the
    /// recognizer holds it weakly; `deinit` therefore detaches too. It hops
    /// to the main actor to do so — `deinit` is nonisolated and runs wherever
    /// the last release lands — so the detach lands a turn later, hence the
    /// await rather than a synchronous assertion.
    func testReleasingTheCoordinatorDetachesItsRecognizer() async {
        let window = makeWindow()

        let system = (window.gestureRecognizers ?? []).count

        do {
            let coordinator = ColumnResizePanCoordinator()
            coordinator.attach(to: window)
            XCTAssertEqual(panRecognizers(on: window).count, 1, "precondition")
            XCTAssertEqual((window.gestureRecognizers ?? []).count, system + 3, "precondition")
        }

        // Let the deinit's main-actor hop run.
        await Task.yield()

        XCTAssertTrue(
            panRecognizers(on: window).isEmpty,
            "a released coordinator must not strand a live recognizer on a live window"
        )
        XCTAssertEqual(
            (window.gestureRecognizers ?? []).count, system,
            "nor its double tap or long press, whose nil delegate would no longer confine them to the grip"
        )
    }

    // MARK: - The reset's recognizers and the drag's events

    /// Beside the pan, a double tap and a long press for the reset, all three
    /// confined to the grip by the same delegate, and all three gone on detach.
    func testTheResetRecognizersComeAndGoWithThePan() {
        let coordinator = ColumnResizePanCoordinator()
        let window = makeWindow()
        // A window on iOS 27 brings recognizers of its own; only the
        // coordinator's are this test's.
        let system = window.gestureRecognizers ?? []
        coordinator.attach(to: window)

        let installed = (window.gestureRecognizers ?? []).filter { added in !system.contains { $0 === added } }
        XCTAssertEqual(installed.count, 3)
        let taps = installed.compactMap { $0 as? UITapGestureRecognizer }
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?.numberOfTapsRequired, 2)
        XCTAssertEqual(installed.compactMap { $0 as? UILongPressGestureRecognizer }.count, 1)
        XCTAssertTrue(installed.allSatisfy { $0.delegate === coordinator })

        coordinator.attach(to: nil)
        XCTAssertEqual((window.gestureRecognizers ?? []).count, system.count)
    }

    /// A drag reports its course, and records only on `.ended`: a cancelled
    /// or failed pan cancels it.
    func testAPanReportsADragThatEndsOrIsCancelled() {
        let coordinator = ColumnResizePanCoordinator()
        var events: [ColumnResizeEvent] = []
        coordinator.onEvent = { events.append($0) }

        coordinator.panChanged(.began, translation: 0)
        coordinator.panChanged(.changed, translation: 30)
        coordinator.panChanged(.ended, translation: 30)
        XCTAssertEqual(events, [.began, .moved(translation: 30), .moved(translation: 30), .ended])

        events = []
        coordinator.panChanged(.began, translation: 0)
        coordinator.panChanged(.ended, translation: 45)
        XCTAssertEqual(events, [.began, .moved(translation: 45), .ended], "a quick drag still lands where it ended")

        for failure in [UIGestureRecognizer.State.cancelled, .failed] {
            events = []
            coordinator.panChanged(.began, translation: 0)
            coordinator.panChanged(failure, translation: 0)
            XCTAssertEqual(events, [.began, .cancelled])
        }

        events = []
        coordinator.panChanged(.changed, translation: 10)
        coordinator.panChanged(.ended, translation: 10)
        XCTAssertEqual(events, [], "nothing without a drag in progress")
    }

    /// The handle leaving its window mid-drag (a fold hides it) cancels the
    /// drag, a turn later, outside SwiftUI's update.
    func testDetachingMidDragCancelsIt() async {
        let coordinator = ColumnResizePanCoordinator()
        var events: [ColumnResizeEvent] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.attach(to: makeWindow())
        coordinator.panChanged(.began, translation: 0)

        coordinator.attach(to: nil)
        XCTAssertEqual(events, [.began], "not inside the update")
        await Task.yield()
        XCTAssertEqual(events, [.began, .cancelled])
    }

    func testTheMenuOffersResetOnlyWithAWidthToClear() {
        let coordinator = ColumnResizePanCoordinator()
        let configuration = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        XCTAssertNil(coordinator.editMenuInteraction(coordinator.menu, menuFor: configuration, suggestedActions: []))
        coordinator.resetTitle = "Reset to Fold"
        let menu = coordinator.editMenuInteraction(coordinator.menu, menuFor: configuration, suggestedActions: [])
        XCTAssertEqual(menu?.children.map(\.title), ["Reset to Fold"])
    }
}
#endif
