#if os(iOS)
import UIKit
import XCTest
@testable import Cabalmail

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
        coordinator.attach(to: first)

        coordinator.attach(to: second)

        XCTAssertTrue(panRecognizers(on: first).isEmpty, "the old window must be left clean")
        XCTAssertEqual(panRecognizers(on: second).count, 1)
    }

    /// #1111's fix, which had no suite that could reach it. The coordinator
    /// can be released before `attach(to: nil)` ever runs, because the
    /// recognizer holds it weakly; `deinit` therefore detaches too. It hops
    /// to the main actor to do so — `deinit` is nonisolated and runs wherever
    /// the last release lands — so the detach lands a turn later, hence the
    /// await rather than a synchronous assertion.
    func testReleasingTheCoordinatorDetachesItsRecognizer() async {
        let window = makeWindow()

        do {
            let coordinator = ColumnResizePanCoordinator()
            coordinator.attach(to: window)
            XCTAssertEqual(panRecognizers(on: window).count, 1, "precondition")
        }

        // Let the deinit's main-actor hop run.
        await Task.yield()

        XCTAssertTrue(
            panRecognizers(on: window).isEmpty,
            "a released coordinator must not strand a live recognizer on a live window"
        )
    }
}
#endif
