import SwiftUI

/// The grip on a pinned list column's trailing edge, which `SplitShell`
/// builds for the iPad split and iPhone Duo's inner display.
///
/// SwiftUI's `NavigationSplitView` doesn't report where a user drags the
/// native column divider, so there is nothing to read back or restore. The
/// column is instead pinned to an explicit width via
/// `.navigationSplitViewColumnWidth(_:)`, and this handle reports a drag's
/// course to the split that owns the column (`ColumnResizeEvent`), which
/// moves the column as it goes and records the width, in the window's scene
/// storage, only when the drag ends (`ListColumnState`). A double tap on the
/// grip, or Reset in the menu a long press on it shows, clears that width;
/// both are offered only while there is one to clear. macOS keeps its native,
/// self-persisting dividers and never renders this handle.
///
/// The handle itself claims no touches. It draws the grip and hands its
/// 22 by 44 pt target to UIKit recognizers installed on the window: a pan
/// that begins only for a horizontal drag starting on the grip, and the
/// double tap and long press (`ColumnResizeGesture`). Taps and vertical
/// scrolls on the grip reach the message row underneath, which a
/// hit-testable strip could not allow (#1075); a horizontal drag there
/// resizes. Everywhere else on the column's edge, trailing swipes included,
/// the recognizers never see a touch.
struct ColumnResizeHandle: View {
    /// The menu's Reset title, or nil while there is no width to clear, when
    /// the grip takes a drag and nothing else.
    let resetTitle: String?
    let onEvent: @MainActor (ColumnResizeEvent) -> Void

    var body: some View {
        // The grip marks where to grab without drawing a second visible rule
        // beside the divider SwiftUI already paints.
        //
        // The target stays FULLY INSIDE the column (no negative inset). The
        // `UISplitViewController` owns the exact column boundary, and a view
        // nudged past the column's bounds gets clipped by UIKit — so the
        // visible grip looked present but never saw the half of the band a
        // user aims at. Keeping the whole target (and the capsule centred on
        // it) inside the column puts the grab target where the eye lands.
        ColumnResizePanTarget(resetTitle: resetTitle, onEvent: onEvent)
            .frame(width: ColumnResizeGesture.grabWidth, height: ColumnResizeGesture.grabHeight)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4, height: 36)
            }
            // Nothing here is hit-testable: the recognizers live on the
            // window and read this view only for its geometry. `pointerStyle`
            // and `hoverEffect` are gone with it — they need a view that takes
            // touches, and the grip stays visible either way.
            .allowsHitTesting(false)
            // Decorative: the resize affordance carries no information a
            // VoiceOver user needs, and the columns remain fully usable at their
            // default sizes.
            .accessibilityHidden(true)
    }
}

#if os(macOS)
/// macOS resizes and persists its columns natively, and only `SplitShell`
/// builds the handle; the stub is here so the handle compiles for both app
/// targets.
private struct ColumnResizePanTarget: View {
    let resetTitle: String?
    let onEvent: @MainActor (ColumnResizeEvent) -> Void

    var body: some View { Color.clear }
}
#else
import UIKit

/// Geometry for the grab target, host for the window-level recognizers, and
/// the view the reset menu presents from.
///
/// The view is inert (`isUserInteractionEnabled = false`): its only jobs are to
/// occupy the target so the recognizers can test a touch against `bounds`, to
/// tell the coordinator which window to install on, and to anchor the menu.
private struct ColumnResizePanTarget: UIViewRepresentable {
    let resetTitle: String?
    let onEvent: @MainActor (ColumnResizeEvent) -> Void

    func makeCoordinator() -> ColumnResizePanCoordinator { ColumnResizePanCoordinator() }

    func makeUIView(context: Context) -> ColumnResizeBandView {
        let view = ColumnResizeBandView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        coordinator.band = view
        view.addInteraction(coordinator.menu)
        view.onMoveToWindow = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: ColumnResizeBandView, context: Context) {
        // Re-read every render: whether there is a width to clear changes
        // with the list the column shows and with each reset.
        context.coordinator.resetTitle = resetTitle
        context.coordinator.onEvent = onEvent
    }
}

/// Inert view occupying the grab target.
final class ColumnResizeBandView: UIView {
    var onMoveToWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?(window)
    }
}

/// Reports drags and resets on the grip from recognizers installed on the
/// window.
///
/// On the window, not on a view of its own, because a recognizer only sees
/// touches delivered to its view's subtree — and the whole point is to sit
/// above the rows without taking anything from them. The target is enforced
/// in `shouldReceive`, so outside it these recognizers never see a touch and
/// the list behaves as though they were not installed.
final class ColumnResizePanCoordinator: NSObject, UIGestureRecognizerDelegate {
    var onEvent: (@MainActor (ColumnResizeEvent) -> Void)?
    /// The menu's Reset title; nil while there is no width to clear.
    var resetTitle: String?
    weak var band: ColumnResizeBandView?
    private(set) lazy var menu = UIEditMenuInteraction(delegate: self)

    private var pan: UIPanGestureRecognizer?
    private var doubleTap: UITapGestureRecognizer?
    private var press: UILongPressGestureRecognizer?
    /// A drag has begun and not yet ended, so a detach has to cancel it.
    private var dragInFlight = false

    private var recognizers: [UIGestureRecognizer] {
        [pan, doubleTap, press].compactMap { $0 }
    }

    func attach(to window: UIWindow?) {
        for recognizer in recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        pan = nil
        doubleTap = nil
        press = nil
        if dragInFlight {
            // The handle left its window mid-drag (a fold hides it, or the
            // column is rebuilt): the drag records nothing. Reported on the
            // next turn, because this runs inside SwiftUI's update of the view
            // that owns the drag's state.
            dragInFlight = false
            let report = onEvent
            Task { @MainActor in report?(.cancelled) }
        }
        guard let window else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        // Touches reach the row as they always would; only a drag that actually
        // recognizes as a resize cancels what it interrupted. Without both
        // delays off, a tap on the grip would be held until this recognizer
        // failed at touch-up — the row would open, late.
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.cancelsTouchesInView = true
        // Offered a touch only while there is a width to clear: then a single
        // tap on the grip reaches its row once the second tap has not come,
        // so a reset never opens, or marks read, the message under the grip.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delaysTouchesBegan = false
        doubleTap.delaysTouchesEnded = true
        doubleTap.cancelsTouchesInView = true
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress))
        press.delaysTouchesBegan = false
        press.delaysTouchesEnded = false
        press.cancelsTouchesInView = true
        for recognizer in [pan, doubleTap, press] as [UIGestureRecognizer] {
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
        }
        self.pan = pan
        self.doubleTap = doubleTap
        self.press = press
    }

    /// Last-resort detach, for a teardown that never routed through
    /// `attach(to: nil)`.
    ///
    /// The window retains the recognizers while they hold this coordinator
    /// only weakly (target and delegate both), so the coordinator can go
    /// first and strand recognizers on a live window — ones whose nil
    /// delegate stops rejecting touches outside the grip and starts
    /// cancelling drags anywhere in the app.
    ///
    /// Hopped onto the main actor because `deinit` is nonisolated and runs
    /// wherever the last release lands, while `view` and
    /// `removeGestureRecognizer` are main-actor isolated. The recognizers are
    /// captured as locals — no part of `self` escapes a deallocation already
    /// underway — and that capture keeps them alive until the hop runs.
    deinit {
        let installed = [pan, doubleTap, press].compactMap { $0 } as [UIGestureRecognizer]
        guard !installed.isEmpty else { return }
        Task { @MainActor in
            for recognizer in installed {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }

    @objc
    private func handlePan(_ pan: UIPanGestureRecognizer) {
        panChanged(pan.state, translation: pan.translation(in: pan.view).x)
    }

    /// A pan state as the handle reports it: a drag's course, with a
    /// cancelled or failed pan cancelling it rather than ending it. The end
    /// carries the pan's last translation too, which a quick drag may not
    /// have delivered as a change. Separate from the selector so tests can
    /// drive it without a touch.
    func panChanged(_ state: UIGestureRecognizer.State, translation: CGFloat) {
        switch state {
        case .began:
            dragInFlight = true
            onEvent?(.began)
        case .changed where dragInFlight:
            onEvent?(.moved(translation: translation))
        case .ended where dragInFlight:
            dragInFlight = false
            onEvent?(.moved(translation: translation))
            onEvent?(.ended)
        case .cancelled where dragInFlight, .failed where dragInFlight:
            dragInFlight = false
            onEvent?(.cancelled)
        default:
            break
        }
    }

    @objc
    private func handleDoubleTap(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, resetTitle != nil else { return }
        onEvent?(.reset)
    }

    @objc
    private func handlePress(_ press: UILongPressGestureRecognizer) {
        guard press.state == .began, resetTitle != nil, let band else { return }
        let grip = CGPoint(x: band.bounds.midX, y: band.bounds.midY)
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: grip))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let band, let window = band.window, window === gestureRecognizer.view else {
            return false
        }
        return ColumnResizeGesture.offersTouch(
            to: gestureRecognizer === pan ? .drag : .reset,
            at: touch.location(in: band),
            band: band.bounds,
            canReset: resetTitle != nil
        )
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return gestureRecognizer === doubleTap || gestureRecognizer === press
        }
        // UIKit reports a translation as a point; the rule reads it as the
        // vector it is.
        let translation = pan.translation(in: pan.view)
        return ColumnResizeGesture.beginsResize(
            translation: CGSize(width: translation.x, height: translation.y)
        )
    }

    /// A touch these recognizers have accepted is the handle's to claim
    /// first, so an edge drag resizes rather than revealing the row's swipe
    /// actions. It costs the other recognizers nothing elsewhere: outside the
    /// grip they are never asked to wait, because these are never handed the
    /// touch. The handle's own three never wait for each other: a horizontal
    /// move fails the long press, and a held press keeps the pan from
    /// beginning.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        !recognizers.contains { $0 === other }
    }
}
/// The reset menu, which UIKit asks for on the main actor.
extension ColumnResizePanCoordinator: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let resetTitle else { return nil }
        return UIMenu(children: [
            UIAction(title: resetTitle) { [weak self] _ in self?.onEvent?(.reset) }
        ])
    }
}
#endif
