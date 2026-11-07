import SwiftUI
import CabalmailKit
#if os(iOS)
import UIKit
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
/// A drag that sees a finger on the display and nothing else.
///
/// A SwiftUI `DragGesture` limited to `.directTouch` (macOS 27): a mouse,
/// a trackpad click-drag, the row's drag onto a folder and the container's
/// trackpad swipe never start it. The first version was an AppKit
/// `NSPanGestureRecognizer` bridged in through `NSGestureRecognizerRepresentable`
/// (`allowedTouchTypes = .direct`, `buttonMask = 0`), and on the device a
/// finger revealed nothing with it. One likely reason is that its delegate's
/// horizontal check (`TrackpadSwipePolicy.beginsSwipe`) was asked at
/// touch-down, with no movement yet, and refused every touch. SwiftUI's own
/// gestures take touch as AppKit's controls do, and need no delegate.
///
/// The drag keeps no state, because the reveal builds it again on every
/// render: each change that reads as a swipe (`beginsSwipe`, on the movement
/// so far) reports `onBegan` and the translation, and the tracker ignores
/// every `began` after the first and an `ended` that none opened. So a drag
/// that stays vertical scrolls the list and never touches the row. Each drag
/// that ends writes one `RowSwipe` line to Settings → Debug Log, which shows
/// whether a finger reaches the row at all.
@available(macOS 27.0, *)
struct TrackpadSwipeRecognizer: Gesture {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: () -> Void

    /// The gesture's input: a finger, and nothing else.
    static let inputKinds: GestureInputKinds = .directTouch

    var body: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local, inputKinds: Self.inputKinds)
            .onChanged { value in
                guard TrackpadSwipePolicy.beginsSwipe(translation: value.translation, velocity: value.velocity)
                else { return }
                onBegan()
                onChanged(value.translation.width)
            }
            .onEnded { value in
                let swipe = TrackpadSwipePolicy.beginsSwipe(translation: value.translation, velocity: value.velocity)
                CabalmailLog.info("RowSwipe", "Finger drag on a row ended at "
                    + "(\(Int(value.translation.width)), \(Int(value.translation.height))): "
                    + (swipe ? "a swipe" : "not a swipe"))
                onEnded(value.translation.width, value.velocity.width)
            }
    }
}
#endif
