import SwiftUI

/// A thin, draggable handle pinned to a column's trailing edge in the wide
/// (regular-width iPad / visionOS) `NavigationSplitView`.
///
/// SwiftUI's `NavigationSplitView` doesn't report where a user drags the
/// native column divider, so there is nothing to read back or restore. To make
/// a chosen split survive cold launches, the column is instead pinned to an
/// explicit width via `.navigationSplitViewColumnWidth(_:)` and this handle
/// drives that width directly. The bound value is backed by `@AppStorage`
/// upstream, so the size persists across launches. macOS keeps its native,
/// self-persisting dividers and never renders this handle.
///
/// The handle itself claims no touches. It draws the grip and hands the grab
/// band to a UIKit pan recognizer installed on the window, which begins only
/// for a horizontal drag that starts in the band (`ColumnResizeGesture`).
/// Taps, vertical scrolls and trailing swipes in the band reach the message
/// row underneath, which a hit-testable strip could not allow (#1075).
struct ColumnResizeHandle: View {
    /// The owning column's width. Writing it both moves the divider (the column
    /// is pinned to this value) and persists it through the upstream binding.
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    var body: some View {
        // The grip marks where to grab without drawing a second visible rule
        // beside the divider SwiftUI already paints.
        //
        // The band stays FULLY INSIDE the column (no negative inset). The
        // `UISplitViewController` owns the exact column boundary, and a view
        // nudged past the column's bounds gets clipped by UIKit — so the
        // visible grip looked present but never saw the half of the band a
        // user aims at. Keeping the whole band (and the capsule centred on it)
        // inside the column puts the grab target where the eye lands.
        ColumnResizePanTarget(width: $width, minWidth: minWidth, maxWidth: maxWidth)
            .frame(maxHeight: .infinity)
            .frame(width: ColumnResizeGesture.grabWidth)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4, height: 36)
            }
            // Nothing here is hit-testable: the recognizer lives on the window
            // and reads this view only for its geometry. `pointerStyle` and
            // `hoverEffect` are gone with it — they need a view that takes
            // touches, and the grip stays visible either way.
            .allowsHitTesting(false)
            // Decorative: the resize affordance carries no information a
            // VoiceOver user needs, and the columns remain fully usable at their
            // default sizes.
            .accessibilityHidden(true)
    }
}

#if os(macOS)
/// macOS resizes and persists its columns natively and never takes the handle
/// branch (`resizableColumns`); the stub is here so the shared view compiles
/// for both app targets.
private struct ColumnResizePanTarget: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    var body: some View { Color.clear }
}
#else
import UIKit

/// Geometry for the grab band, and host for the window-level pan recognizer.
///
/// The view is inert (`isUserInteractionEnabled = false`): its only jobs are to
/// occupy the band so the recognizer can test a touch against `bounds`, and to
/// tell the coordinator which window to install on.
private struct ColumnResizePanTarget: UIViewRepresentable {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func makeCoordinator() -> ColumnResizePanCoordinator { ColumnResizePanCoordinator() }

    func makeUIView(context: Context) -> ColumnResizeBandView {
        let view = ColumnResizeBandView()
        view.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        coordinator.band = view
        view.onMoveToWindow = { [weak coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: ColumnResizeBandView, context: Context) {
        // Re-bound every render: the range narrows with the split's own width,
        // and the binding is a value the coordinator can only read from here.
        context.coordinator.width = $width
        context.coordinator.minWidth = minWidth
        context.coordinator.maxWidth = maxWidth
    }
}

/// Inert view occupying the grab band.
final class ColumnResizeBandView: UIView {
    var onMoveToWindow: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoveToWindow?(window)
    }
}

/// Drives the column width from a pan recognizer installed on the window.
///
/// On the window, not on a view of its own, because a recognizer only sees
/// touches delivered to its view's subtree — and the whole point is to sit
/// above the rows without taking anything from them. The band is enforced in
/// `shouldReceive`, so outside it this recognizer never sees a touch and the
/// list behaves as though it were not installed.
final class ColumnResizePanCoordinator: NSObject, UIGestureRecognizerDelegate {
    var width: Binding<CGFloat>?
    var minWidth: CGFloat = 0
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    weak var band: ColumnResizeBandView?

    private var recognizer: UIPanGestureRecognizer?
    /// Width captured when a drag begins, so each frame's delta applies to a
    /// stable base rather than compounding the previous frame's result.
    private var dragAnchor: CGFloat?

    func attach(to window: UIWindow?) {
        if let recognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
            self.recognizer = nil
        }
        guard let window else { return }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.delegate = self
        // Touches reach the row as they always would; only a drag that actually
        // recognizes as a resize cancels what it interrupted. Without both
        // delays off, a tap in the band would be held until this recognizer
        // failed at touch-up — the row would open, late.
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        pan.cancelsTouchesInView = true
        window.addGestureRecognizer(pan)
        recognizer = pan
    }

    /// Last-resort detach, for a teardown that never routed through
    /// `attach(to: nil)`.
    ///
    /// The window retains the recognizer while the recognizer holds this
    /// coordinator only weakly (target and delegate both), so the coordinator
    /// can go first and strand a recognizer on a live window — one whose nil
    /// delegate stops rejecting touches outside the band and starts cancelling
    /// drags anywhere in the app.
    ///
    /// Hopped onto the main actor because `deinit` is nonisolated and runs
    /// wherever the last release lands, while `view` and
    /// `removeGestureRecognizer` are main-actor isolated. The recognizer is
    /// captured as a local — no part of `self` escapes a deallocation already
    /// underway — and that capture keeps it alive until the hop runs.
    deinit {
        if let recognizer {
            Task { @MainActor in
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }
    }

    @objc
    private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let width else { return }
        switch pan.state {
        case .began:
            dragAnchor = width.wrappedValue
        case .changed:
            let anchor = dragAnchor ?? width.wrappedValue
            dragAnchor = anchor
            width.wrappedValue = ColumnResizeGesture.resizedWidth(
                anchor: anchor,
                translation: pan.translation(in: pan.view).x,
                minWidth: minWidth,
                maxWidth: maxWidth
            )
        default:
            dragAnchor = nil
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard let band, let window = band.window, window === gestureRecognizer.view else {
            return false
        }
        return ColumnResizeGesture.acceptsTouch(at: touch.location(in: band), band: band.bounds)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        // UIKit reports a translation as a point; the rule reads it as the
        // vector it is.
        let translation = pan.translation(in: pan.view)
        return ColumnResizeGesture.beginsResize(
            translation: CGSize(width: translation.x, height: translation.y)
        )
    }

    /// A touch this recognizer has accepted is the handle's to claim first, so
    /// an edge drag resizes rather than revealing the row's swipe actions. It
    /// costs the other recognizers nothing elsewhere: outside the band they are
    /// never asked to wait, because this one is never handed the touch.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
