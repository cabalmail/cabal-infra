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
        Color.clear
            .frame(width: 16)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 4, height: 36)
            }
            .contentShape(Rectangle())
            // Shift the strip outward so it centres on the column's edge rather
            // than sitting fully inside the column.
            .padding(.trailing, -8)
            .gesture(
                DragGesture(minimumDistance: 1)
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
