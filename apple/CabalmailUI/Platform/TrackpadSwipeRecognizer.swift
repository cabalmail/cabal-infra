import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// The input behind a message row's drawn swipe reveal (`TrackpadSwipe.swift`):
// the one input the 27 swipe-actions container misses on each platform that
// draws one (`HostPlatform.drawsRowSwipeReveal`).
//
// - iPadOS: a trackpad's two-finger swipe. The container's reveal is driven
//   by touches, and UIKit delivers a trackpad swipe as scroll input.
// - macOS: a finger on a touch display (the MacBook Pro with PROLED XDR
//   Display). The container's reveal is driven by the trackpad's scroll
//   events and never answers a finger.
//
// So the name says trackpad, and on the Mac it is a finger: one type on both
// platforms keeps the reveal platform-neutral. visionOS draws no reveal, and
// has no gesture-recognizer bridge, so it gets an inert stand-in that is
// never attached.

#if os(visionOS)
/// visionOS draws no reveal of its own (`HostPlatform.drawsRowSwipeReveal`),
/// and SwiftUI has no `UIGestureRecognizerRepresentable` there. This lets the
/// reveal compile; nothing ever builds it.
struct TrackpadSwipeRecognizer: Gesture {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: () -> Void

    var body: some Gesture {
        TapGesture()
    }
}
#elseif canImport(UIKit)
/// A pan that sees trackpad scrolling and nothing else.
///
/// `allowedTouchTypes` is empty, so it is never handed a touch -- every touch
/// stays with the native swipe, the row's button, and the list's own
/// scrolling, and none of them is ever asked to wait for it. It takes
/// `.continuous` scroll input only: a trackpad's two-finger swipe (and a Magic
/// Mouse's surface), not a wheel's discrete steps.
struct TrackpadSwipeRecognizer: UIGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: () -> Void

    /// The recognizer as installed, minus its delegate. Separate so tests can
    /// read the configuration that decides which input it sees.
    static func configuredRecognizer() -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .continuous
        pan.name = "cabalmail.trackpadSwipe"
        return pan
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = Self.configuredRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Delegate {
        Delegate()
    }

    final class Delegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            let velocity = pan.velocity(in: pan.view)
            return TrackpadSwipePolicy.beginsSwipe(
                translation: CGSize(width: translation.x, height: translation.y),
                velocity: CGSize(width: velocity.x, height: velocity.y)
            )
        }

        /// The list's scroll view takes trackpad scrolling too, and would start
        /// scrolling on a swipe's slight vertical wobble. It waits for this pan
        /// to decide, which it does on the first movement: a vertical scroll
        /// fails here at once and goes on to scroll the list.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
#elseif canImport(AppKit)
/// A pan that takes a finger on the display and nothing else, beside the
/// list's own scrolling.
///
/// `allowedTouchTypes` is `.direct` and `buttonMask` is 0, so a mouse, a
/// trackpad click-drag, the row's drag onto a folder and the container's
/// trackpad swipe never start it. It recognizes alongside every other
/// gesture, the scroll view's touch scrolling included, and decides each
/// touch's axis from the movement (`TrackpadSwipePolicy.touchAxis`): a
/// sideways one drives the reveal, any other is left to scroll the list.
///
/// The versions before this, as the device showed (2026-11-07):
/// - The first was this recognizer with a delegate that refused to begin
///   unless the movement so far was sideways. Asked at touch-down, before
///   any movement, it refused every touch, and a finger revealed nothing.
/// - A SwiftUI `DragGesture(inputKinds: .directTouch)` then swiped, but
///   attached with `.gesture` it claimed every finger that moved on a row,
///   and the mail list stopped scrolling under a finger.
/// - Attached with `.simultaneousGesture` it still did, though it ignored the
///   vertical ones, so a SwiftUI drag on a row keeps a finger from the list's
///   scrolling either way. This recognizer, in the first version's build,
///   didn't.
@available(macOS 27.0, *)
struct TrackpadSwipeRecognizer: NSGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: () -> Void

    /// The recognizer as installed, minus its delegate. Separate so tests can
    /// read the configuration that decides which input it sees.
    static func configuredRecognizer() -> NSPanGestureRecognizer {
        let pan = NSPanGestureRecognizer()
        pan.allowedTouchTypes = .direct
        pan.buttonMask = 0
        return pan
    }

    func makeNSGestureRecognizer(context: Context) -> NSPanGestureRecognizer {
        let pan = Self.configuredRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSPanGestureRecognizer, context: Context) {
        let point = recognizer.translation(in: recognizer.view)
        let translation = CGSize(width: point.x, height: point.y)
        let touch = context.coordinator
        switch recognizer.state {
        case .began, .changed:
            if touch.axis == nil, let axis = TrackpadSwipePolicy.touchAxis(translation: translation) {
                touch.axis = axis
                if axis == .swipe { onBegan() }
            }
            if touch.axis == .swipe { onChanged(translation.width) }
        case .ended:
            if touch.axis == .swipe { onEnded(translation.width, recognizer.velocity(in: recognizer.view).x) }
            touch.axis = nil
        case .cancelled, .failed:
            if touch.axis == .swipe { onCancelled() }
            touch.axis = nil
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Touch {
        Touch()
    }

    /// One touch's state, kept across the recognizer's calls, and its
    /// delegate.
    final class Touch: NSObject, NSGestureRecognizerDelegate {
        /// What this touch is, once it has moved far enough to tell.
        var axis: TrackpadSwipePolicy.TouchAxis?

        /// Beside every other gesture: the list's touch scrolling above all.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: NSGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif

extension View {
    /// Attaches a row's swipe input (`TrackpadSwipeReveal`). Each platform's
    /// input is a gesture recognizer; on macOS it recognizes beside the
    /// list's scrolling of its own accord (`Touch`).
    @available(macOS 27.0, *)
    func rowSwipeInput(_ input: TrackpadSwipeRecognizer) -> some View {
        gesture(input)
    }
}
