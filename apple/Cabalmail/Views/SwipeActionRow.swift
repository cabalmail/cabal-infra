import SwiftUI
#if os(iOS)
import UIKit
#endif

// Hand-rolled swipe actions for the virtualized message list.
//
// `.swipeActions` is `List`-only, and the list is now a `ScrollView` +
// `LazyVStack` (see `project_apple_list_virtualization` / the
// `virtualizedList` doc comment), so touch users lost swipe-to-archive
// when the list was virtualized. This restores it: a trailing (right-to-
// left) swipe disposes, a leading (left-to-right) swipe toggles read,
// matching Mail and the pre-virtualization `.swipeActions(edge:)` wiring.
//
// The hard part is coexisting with the vertical scroll. A plain SwiftUI
// `DragGesture` recognizes vertical drags too and preempts the scroll
// view, so it can't be used here. Instead `SwipePanGesture` bridges a
// UIKit `UIPanGestureRecognizer` whose delegate only lets it BEGIN when
// the pan is horizontal (`abs(vx) > abs(vy)`); vertical pans fall through
// to the enclosing scroll view untouched. This mirrors the existing
// `ModifierClickGesture` UIKit bridge.
//
// macOS / visionOS render the plain tappable row with no swipe -- those
// platforms dispose via the context menu and (macOS) the keyboard.

/// One swipe action. `tint` is the revealed background; `perform` runs on
/// full-swipe commit or on a tap of the rested-open button.
struct SwipeActionSpec {
    let systemImage: String
    let title: String
    let tint: Color
    let role: ButtonRole?
    let perform: () -> Void

    init(
        systemImage: String,
        title: String,
        tint: Color,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.role = role
        self.perform = perform
    }
}

/// A fixed-height list row that reveals a leading and/or trailing action
/// on a horizontal swipe. A tap selects the row (`onSelect`) when closed,
/// or closes the swipe when open. `openUID` is shared across the list so
/// only one row rests open at a time.
struct SwipeActionRow<Content: View>: View {
    let rowUID: UInt32
    @Binding var openUID: UInt32?
    let height: CGFloat
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    // Rest-open width per action, and the full-swipe commit threshold as a
    // fraction of the row width. Both are deliberately easy to tune -- the
    // gesture feel is the thing that needs on-device iteration.
    private static var actionWidth: CGFloat { 80 }
    private static var commitFraction: CGFloat { 0.45 }

    @State private var offset: CGFloat = 0
    // The resting offset captured at the start of a pan, so the live
    // translation is added to where the row already sat (closed or open).
    @State private var dragStartOffset: CGFloat?
    // Claim the shared open slot once per gesture rather than every frame.
    @State private var claimedOpen = false

    var body: some View {
        #if os(iOS)
        GeometryReader { geo in
            swipeStack(width: geo.size.width)
        }
        .frame(height: height)
        .onChange(of: openUID) { _, newValue in
            // Another row opened (or the list cleared the slot); fold closed.
            if newValue != rowUID, offset != 0 { closeRow() }
        }
        #else
        plainRow
        #endif
    }

    /// macOS / visionOS: just the tappable row, no swipe affordance.
    private var plainRow: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: height)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
    }

    #if os(iOS)
    private func swipeStack(width: CGFloat) -> some View {
        let commitDistance = max(width * Self.commitFraction, Self.actionWidth + 40)
        return ZStack {
            actionLayer
            content()
                .frame(width: width, height: height, alignment: .topLeading)
                .background(rowBackground)
                .contentShape(Rectangle())
                .offset(x: offset)
                .gesture(panGesture(width: width, commitDistance: commitDistance))
                .onTapGesture { offset == 0 ? onSelect() : closeRow() }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// The colored action regions behind the row. Each grows with the
    /// row's displacement so it stretches out from the edge as you pull,
    /// then rests at `actionWidth`. Anchored to the inner edge so the
    /// icon/label stay put while the region widens.
    private var actionLayer: some View {
        HStack(spacing: 0) {
            if let leading {
                actionButton(leading, width: max(0, offset), alignment: .trailing)
            }
            Spacer(minLength: 0)
            if let trailing {
                actionButton(trailing, width: max(0, -offset), alignment: .leading)
            }
        }
    }

    private func actionButton(
        _ spec: SwipeActionSpec,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Button(role: spec.role) {
            perform(spec)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: spec.systemImage)
                Text(spec.title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.horizontal, 10)
            .background(spec.tint)
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .frame(height: height)
        .clipped()
        .allowsHitTesting(width > 0)
    }

    private func panGesture(width: CGFloat, commitDistance: CGFloat) -> SwipePanGesture {
        SwipePanGesture { phase in
            switch phase {
            case .changed(let translation):
                let start = dragStartOffset ?? offset
                if dragStartOffset == nil { dragStartOffset = start }
                offset = clamp(start + translation, width: width)
                if !claimedOpen {
                    openUID = rowUID
                    claimedOpen = true
                }
            case .ended(let translation, let velocity):
                let start = dragStartOffset ?? offset
                dragStartOffset = nil
                settle(
                    landing: clamp(start + translation + velocity * 0.1, width: width),
                    commitDistance: commitDistance
                )
            }
        }
    }

    /// Clamp the row displacement to the side(s) that actually have an
    /// action: no leading action means no rightward slide, and vice versa.
    private func clamp(_ value: CGFloat, width: CGFloat) -> CGFloat {
        let low = trailing == nil ? 0 : -width
        let high = leading == nil ? 0 : width
        return min(max(value, low), high)
    }

    private func settle(landing: CGFloat, commitDistance: CGFloat) {
        let spec = landing < 0 ? trailing : leading
        guard let spec else { closeRow(); return }
        if abs(landing) >= commitDistance {
            perform(spec)
        } else if abs(offset) >= Self.actionWidth * 0.5 {
            withAnimation(.snappy(duration: 0.22)) {
                offset = landing < 0 ? -Self.actionWidth : Self.actionWidth
            }
        } else {
            closeRow()
        }
    }

    private func perform(_ spec: SwipeActionSpec) {
        spec.perform()
        // The row either vanishes (dispose prunes it) or stays put
        // (toggle-read); either way drop the open state back to closed.
        closeRow()
    }

    private func closeRow() {
        withAnimation(.snappy(duration: 0.22)) { offset = 0 }
        claimedOpen = false
        if openUID == rowUID { openUID = nil }
    }
    #endif
}

#if os(iOS)
/// UIKit-bridged horizontal pan. Only begins when the gesture is more
/// horizontal than vertical, so vertical drags stay with the enclosing
/// scroll view. Reports translation/velocity along x in points.
struct SwipePanGesture: UIGestureRecognizerRepresentable {
    enum Phase {
        case changed(CGFloat)
        case ended(translation: CGFloat, velocity: CGFloat)
    }

    let onPhase: (Phase) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed:
            onPhase(.changed(translation))
        case .ended, .cancelled, .failed:
            let velocity = recognizer.velocity(in: recognizer.view).x
            onPhase(.ended(translation: translation, velocity: velocity))
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Begin only for predominantly-horizontal pans; let the scroll view
        // own vertical drags so the list still scrolls normally.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}
#endif
