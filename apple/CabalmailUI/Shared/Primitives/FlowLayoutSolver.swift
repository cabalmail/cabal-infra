import CoreGraphics

/// The geometry behind `FlowLayout`, lifted out of the `Layout` conformance
/// so the row-breaking and overflow rules can be exercised without a view
/// hierarchy. Origins are relative to the layout's own top-leading corner;
/// the caller offsets them into its bounds.
struct FlowLayoutSolver {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    struct Solution: Equatable {
        var frames: [CGRect]
        var size: CGSize
    }

    /// Lays `idealSizes` out in rows no wider than `lineWidth`.
    ///
    /// `measure` re-measures one item against a proposed width, and is called
    /// only for an item whose ideal width overflows the line: wrapping
    /// *between* items can never make a single item narrower, so an item
    /// placed at its ideal width would run past the container and be cut by
    /// the enclosing clip. Proposing the line width instead hands the item
    /// its own chance to truncate or wrap.
    func solve(
        idealSizes: [CGSize],
        lineWidth: CGFloat,
        measure: (Int, CGFloat) -> CGSize
    ) -> Solution {
        var frames: [CGRect] = []
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for (index, ideal) in idealSizes.enumerated() {
            var size = ideal
            if lineWidth.isFinite, ideal.width > lineWidth {
                size = measure(index, lineWidth)
                size.width = min(size.width, lineWidth)
            }
            if cursorX > 0, cursorX + horizontalSpacing + size.width > lineWidth {
                widestRow = max(widestRow, cursorX)
                cursorY += rowHeight + verticalSpacing
                cursorX = 0
                rowHeight = 0
            }
            if cursorX > 0 { cursorX += horizontalSpacing }
            frames.append(CGRect(origin: CGPoint(x: cursorX, y: cursorY), size: size))
            cursorX += size.width
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, cursorX)
        return Solution(
            frames: frames,
            size: CGSize(
                width: lineWidth.isFinite ? min(widestRow, lineWidth) : widestRow,
                height: frames.isEmpty ? 0 : cursorY + rowHeight
            )
        )
    }
}
