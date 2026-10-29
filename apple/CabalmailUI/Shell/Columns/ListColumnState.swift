import CoreGraphics

/// What changes while a list column is being used: a drag on its handle in
/// progress, and the fold the column has applied. Held in `@State` by the
/// split that owns the column; the width itself is `ListColumnPolicy`'s.
///
/// A drag records nothing until it ends: frames during it only move the
/// column (`liveWidth(for:)`), and `endDrag(tab:)` hands back the one width to
/// store. A cancelled drag, a drag a fold interrupts, and a drag on a list
/// the column has stopped showing store nothing.
struct ListColumnState: Equatable, Sendable {
    struct Drag: Equatable, Sendable {
        let tab: ListColumnTab
        /// The width when the drag began, so each frame's translation applies
        /// to a stable base (#1059).
        let anchor: CGFloat
        var width: CGFloat
    }

    private(set) var fold: FoldState = .none
    private(set) var drag: Drag?

    /// The width a drag in progress on `tab` has reached.
    func liveWidth(for tab: ListColumnTab) -> CGFloat? {
        drag?.tab == tab ? drag?.width : nil
    }

    /// No drag starts on a folded column: its handle is hidden.
    mutating func beginDrag(tab: ListColumnTab, from width: CGFloat) {
        drag = fold.isFolded ? nil : Drag(tab: tab, anchor: width, width: width)
    }

    mutating func moveDrag(tab: ListColumnTab, translation: CGFloat, bounds: ClosedRange<CGFloat>) {
        guard let current = drag else { return }
        guard current.tab == tab else {
            drag = nil
            return
        }
        drag?.width = ColumnResizeGesture.resizedWidth(
            anchor: current.anchor,
            translation: translation,
            minWidth: bounds.lowerBound,
            maxWidth: bounds.upperBound
        )
    }

    /// The width to record for `tab`, once; nil when no drag on it was in
    /// progress.
    mutating func endDrag(tab: ListColumnTab) -> CGFloat? {
        defer { drag = nil }
        guard let drag, drag.tab == tab else { return nil }
        return drag.width
    }

    mutating func cancelDrag() {
        drag = nil
    }

    /// Applies the window's new fold. Any active fold ends a drag unsaved.
    mutating func follow(_ new: FoldState) {
        if new.isFolded { drag = nil }
        fold = new
    }
}
