import SwiftUI
#if os(visionOS)
#elseif canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
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
//   events, and AppKit hands a direct touch only to gesture recognizers.
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
/// A pan that sees a finger on the display and nothing else.
///
/// `allowedTouchTypes` is `.direct` and `buttonMask` is 0, so a mouse drag or
/// a trackpad click-drag never starts it -- the row's click, its drag onto a
/// folder, and the container's own trackpad swipe keep the pointer to
/// themselves. A trackpad's two-finger swipe is scroll input, which a pan
/// never sees. This is the pattern Apple's Tech Talk "Bring Touch to your Mac
/// app" gives for a touch-only recognizer.
@available(macOS 26.0, *)
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

    final class Delegate: NSObject, NSGestureRecognizerDelegate {
        /// Horizontal-dominant only, as on iPadOS: a finger scrolling the list
        /// that strays sideways stays with the list.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? NSPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            let velocity = pan.velocity(in: pan.view)
            return TrackpadSwipePolicy.beginsSwipe(
                translation: CGSize(width: translation.x, height: translation.y),
                velocity: CGSize(width: velocity.x, height: velocity.y)
            )
        }

        /// The list's scroll view scrolls under a finger too, and would start
        /// on a swipe's slight vertical wobble. It waits for this pan to
        /// decide, which it does on the first movement.
        func gestureRecognizer(
            _ gestureRecognizer: NSGestureRecognizer,
            shouldBeRequiredToFailBy other: NSGestureRecognizer
        ) -> Bool {
            other.view is NSScrollView
        }
    }
}
#endif
