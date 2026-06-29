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
struct ColumnResizeHandle: View {
    /// The owning column's width. Writing it both moves the divider (the column
    /// is pinned to this value) and persists it through the upstream binding.
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    /// Width captured when a drag begins, so each frame's delta applies to a
    /// stable base rather than compounding the previous frame's result.
    @State private var dragAnchor: CGFloat?

    var body: some View {
        // A wide, transparent strip straddling the system divider gives a
        // forgiving grab target; the faint capsule marks where to grab without
        // drawing a second visible rule beside the divider SwiftUI already paints.
        //
        // The strip stays FULLY INSIDE the column (no negative inset). The
        // `UISplitViewController` owns the exact column boundary, and an overlay
        // nudged past the column's bounds gets clipped out of hit-testing by
        // UIKit — so the visible grip looked present but ignored every touch
        // because the half a user aims at was the clipped, dead half. Keeping
        // the whole strip (and the capsule centred on it) inside the column
        // puts the grab target where the eye lands.
        //
        // A near-zero-opacity fill rather than `Color.clear` guarantees the
        // strip is hit-testable, and `highPriorityGesture` lets the drag win
        // over the message list's scroll/tap underneath.
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: 22)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4, height: 36)
            }
            .contentShape(Rectangle())
            // Measure in GLOBAL space, not the handle's local space. The handle
            // is pinned to the column's trailing edge, so resizing moves it —
            // and a local-space translation would be measured against that
            // moving origin, under-reporting by the amount the column just grew
            // and feeding back on itself (the divider tracked the finger at
            // roughly half speed and jittered between frames). Global space is
            // fixed to the screen, so the translation is the true finger delta.
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let anchor = dragAnchor ?? width
                        if dragAnchor == nil { dragAnchor = anchor }
                        width = min(max(anchor + value.translation.width, minWidth), maxWidth)
                    }
                    .onEnded { _ in dragAnchor = nil }
            )
            // `pointerStyle(.columnResize)` would suit the trackpad pointer but
            // is macOS/visionOS-only; iPadOS gets the hover highlight instead.
            #if os(iOS)
            .hoverEffect(.highlight)
            #endif
            // Decorative: the resize affordance carries no information a
            // VoiceOver user needs, and the columns remain fully usable at their
            // default sizes.
            .accessibilityHidden(true)
    }
}
