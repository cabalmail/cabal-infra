import SwiftUI

/// A line-wrapping container: places its subviews left-to-right and wraps to
/// a new row when the next subview would overflow the proposed width. The
/// message detail header uses it to lay out per-address recipient elements
/// — each carrying its own context menu — the way a single wrapping `Text`
/// line used to read, which a plain `HStack` can't do.
///
/// The arithmetic lives in `FlowLayoutSolver`; this type only measures
/// subviews and places what the solver decides.
struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        solve(subviews: subviews, lineWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let solution = solve(subviews: subviews, lineWidth: bounds.width)
        for (subview, frame) in zip(subviews, solution.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                // The solver's size, not the subview's ideal: an oversized
                // subview is proposed the line width so it truncates or
                // wraps instead of overflowing the clip.
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func solve(subviews: Subviews, lineWidth: CGFloat) -> FlowLayoutSolver.Solution {
        let solver = FlowLayoutSolver(
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing
        )
        return solver.solve(
            idealSizes: subviews.map { $0.sizeThatFits(.unspecified) },
            lineWidth: lineWidth
        ) { index, width in
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}
