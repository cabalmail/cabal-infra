import SwiftUI
#if os(iOS)
import UIKit
#endif

// Hand-rolled swipe-actions row for the virtualized message list on touch
// platforms (iOS / iPadOS / visionOS). It replaces the per-row embedded `List`
// that `SwipeActionRow` borrows native `.swipeActions` from: a stack of
// UICollectionView-backed Lists nested in the outer `LazyVStack` made a
// background scene-update relayout exceed the 10-second watchdog (0x8BADF00D),
// killing the app a second or two after the user archived a message and
// backgrounded the app -- even for a folder of fewer than 30 messages.
//
// This draws the reveal with a plain `ZStack` + a `DragGesture`, so a row is
// just views: no nested scroll view, no collection view, nothing to lay out
// beyond the row content itself.
//
// macOS keeps `SwipeActionRow` (native `.swipeActions`): there the swipe is a
// two-finger trackpad SCROLL gesture a SwiftUI `DragGesture` can't read, and
// the Mac has no scene-update watchdog pressure. The platform split lives in
// `messageRow` (see `MessageListView+Selection`).

/// Resting (open) width of a single action button.
private let swipeButtonWidth: CGFloat = 74
/// Past this fraction of the row's width, releasing fires the action directly
/// (the system list's full-swipe behavior).
private let swipeFullFraction: CGFloat = 0.5
/// Minimum open travel before a release rests open rather than snapping shut.
private let swipeOpenThreshold: CGFloat = swipeButtonWidth * 0.6

struct SwipeRow<Content: View>: View {
    let height: CGFloat
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    /// Identity of the row's current content (the envelope UID in the real
    /// list). When it changes, a recycled `LazyVStack` row slot is now showing
    /// a different message, so any open/translated state is reset.
    let resetKey: AnyHashable
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0   // live content x-translation
    @State private var rest: CGFloat = 0     // resting offset: 0 or ±buttonWidth
    @State private var axis: Axis?           // locked once the drag's direction is known
    @State private var armed = false         // crossed the full-swipe line this drag

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack {
                actionLayer(width: width)
                content()
                    // Match the 16pt horizontal inset the embedded-List path
                    // gave rows via `listRowInsets`, so the content lines up
                    // with `placeholderRow` (also inset 16). The tint
                    // background still fills the full row width.
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(rowBackground)
                    .contentShape(Rectangle())
                    .offset(x: offset)
                    .onTapGesture { tapContent() }
                    .simultaneousGesture(dragGesture(width: width))
            }
        }
        .frame(height: height)
        .clipped()
        .onChange(of: resetKey) { _, _ in close(animated: false) }
    }

    // MARK: Reveal

    /// The colored action sitting behind the content. It's anchored to the
    /// edge the swipe exposes and grows with the drag so the color fills the
    /// row on a full swipe -- the system list's look.
    @ViewBuilder
    private func actionLayer(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if offset > 0, let leading {
                actionButton(leading, width: width)
                Spacer(minLength: 0)
            } else if offset < 0, let trailing {
                Spacer(minLength: 0)
                actionButton(trailing, width: width)
            }
        }
    }

    private func actionButton(_ spec: SwipeActionSpec, width: CGFloat) -> some View {
        Button { fire(spec, width: width) } label: {
            VStack(spacing: 2) {
                Image(systemName: spec.systemImage)
                    .font(.body)
                Text(spec.title)
                    .font(.caption2)
            }
            .foregroundStyle(.white)
            .frame(width: max(swipeButtonWidth, abs(offset)))
            .frame(maxHeight: .infinity)
            .background(spec.tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: Gesture

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal : .vertical
                }
                guard axis == .horizontal else { return }
                offset = resist(rest + value.translation.width)
                updateArm(width: width)
            }
            .onEnded { _ in
                let wasHorizontal = axis == .horizontal
                axis = nil
                guard wasHorizontal else { return }
                let full = width * swipeFullFraction
                if abs(offset) >= full, let spec = action(for: offset) {
                    fire(spec, width: width)
                } else if abs(offset) >= swipeOpenThreshold, action(for: offset) != nil {
                    openRest()
                } else {
                    close(animated: true)
                }
            }
    }

    /// Clamp the live offset to a side that actually has an action, with a
    /// little rubber-band give past a full reveal so it never feels stuck.
    private func resist(_ proposed: CGFloat) -> CGFloat {
        if proposed > 0, leading == nil { return rubberBand(proposed) }
        if proposed < 0, trailing == nil { return -rubberBand(-proposed) }
        return proposed
    }

    private func rubberBand(_ distance: CGFloat) -> CGFloat {
        // Heavily damped travel toward an edge with no action.
        min(distance, 16) + max(0, distance - 16) * 0.1
    }

    private func updateArm(width: CGFloat) {
        let full = width * swipeFullFraction
        let nowArmed = abs(offset) >= full && action(for: offset) != nil
        if nowArmed != armed {
            armed = nowArmed
            if nowArmed { impact() }
        }
    }

    private func action(for offset: CGFloat) -> SwipeActionSpec? {
        if offset > 0 { return leading }
        if offset < 0 { return trailing }
        return nil
    }

    // MARK: Transitions

    private func tapContent() {
        if rest != 0 {
            close(animated: true)
        } else {
            onSelect()
        }
    }

    private func openRest() {
        let target: CGFloat = offset > 0 ? swipeButtonWidth : -swipeButtonWidth
        withAnimation(.snappy(duration: 0.2)) {
            offset = target
            rest = target
        }
    }

    private func close(animated: Bool) {
        armed = false
        if animated {
            withAnimation(.snappy(duration: 0.2)) { offset = 0; rest = 0 }
        } else {
            offset = 0
            rest = 0
        }
    }

    /// Fire the action: slide the content off in the swipe direction (the row
    /// is typically removed by the action), buzz, run it, then reset so a
    /// recycled slot starts closed.
    private func fire(_ spec: SwipeActionSpec, width: CGFloat) {
        impact()
        withAnimation(.easeOut(duration: 0.2)) {
            offset = offset > 0 ? width : -width
        }
        spec.perform()
        // Reset after the slide so the same `@State` reused for the next
        // envelope in this slot doesn't inherit the offset.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            offset = 0
            rest = 0
            armed = false
        }
    }

    private func impact() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}
