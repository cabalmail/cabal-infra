import CoreGraphics

/// The iPhone Duo spec's 44 pt rule for book pose: nothing Cabalmail draws
/// to be read or tapped comes within 44 pt of the crease.
///
/// Measured from the crease LINE, the middle of the division region
/// `FoldState` carries (the region is the 40 pt band with the system's 20 pt
/// margins either side of the line): on the Duo's 951 pt inner display the
/// band runs from 455.5 to 495.5, so the keep-out runs from 431.5 to 519.5.
/// The spec's own numbers read it that way, its options having been 20, 44
/// and 64 pt with 20 being the band itself.
///
/// The list column ends at the band's leading edge in book pose
/// (`ListColumnPolicy`) and the reader starts there, so the keep-out reaches
/// into both: the list keeps its own controls short of it, and the reader
/// starts its content past it. Laptop pose, a flat or closed Duo and every
/// other device have no vertical fold, and every rule here answers 0.
enum CreaseClearance {
    static let distance: CGFloat = 44
    /// The split draws a 1 pt separator after the list, so a reader can start
    /// a point past the band's leading edge and still be the column beside it.
    static let edgeTolerance: CGFloat = 1

    /// The keep-out in window x: the crease line plus and minus `distance`;
    /// nil unless the fold runs top to bottom.
    static func keepOut(_ fold: FoldState) -> ClosedRange<CGFloat>? {
        guard case .vertical(let crease) = fold else { return nil }
        return (crease.midX - distance)...(crease.midX + distance)
    }

    /// How far the keep-out reaches into a column on the leading page that
    /// ends at `trailingEdge` (window x): 0 with no vertical fold, for a
    /// column that ends short of the keep-out, and for one the line runs
    /// through, which is not on the leading page.
    static func trailingClearance(fold: FoldState, columnEndingAt trailingEdge: CGFloat) -> CGFloat {
        guard case .vertical(let crease) = fold, let keepOut = keepOut(fold),
              trailingEdge <= crease.midX else { return 0 }
        return max(0, trailingEdge - keepOut.lowerBound)
    }

    /// The leading inset that starts a column's content past the keep-out,
    /// for a column that starts at the band or after it (window x). 0 with
    /// no vertical fold, and for a column that starts before the band: with
    /// the addresses inspector open the list cannot reach the crease and the
    /// reader runs across it, until Decision 10 settles the inspector.
    static func leadingInset(fold: FoldState, columnStartingAt leadingEdge: CGFloat) -> CGFloat {
        guard case .vertical(let crease) = fold, let keepOut = keepOut(fold),
              leadingEdge >= crease.minX - edgeTolerance else { return 0 }
        return max(0, keepOut.upperBound - leadingEdge)
    }
}
