import SwiftUI

/// The width of a list column pinned beside a reader, and when its handle
/// shows: the iPad split and iPhone Duo's inner display (`SplitShell`), and
/// the one view tree's Mail, Feeds and Search splits after it.
///
/// UIKit holds a list to an explicit `.navigationSplitViewColumnWidth`, a
/// fold included: in book pose on the Duo simulator a 360 pt list stayed
/// 360, and a 456 pt one tiled with the reader from 457 (measured
/// 2026-10-27). So the fold rule is this type's, not the system's:
///
/// - In book pose (a vertical fold) the list ends at the crease band's
///   leading edge, the point the system's own split snaps to, where its
///   range can seat that width, and the handle hides.
/// - Lying flat with no width of its own, the list ends at the same edge of
///   the band, inactive there (`\.foldDivision`), so folding moves nothing.
/// - Otherwise it keeps the width the user left it at in this window, or
///   360 pt.
///
/// The crease band is used only when the column's range can seat it, so a
/// split that a band merely clips, or one with a sidebar tiled before the
/// list, keeps its own width. Laptop pose pins nothing.
///
/// The range is 320 pt in a split wider than tall (the spec's floor) and
/// 300 pt in a taller one, where 320 beside the reader's 360 would not fit
/// a 669 pt window, up to the split less the reader's floor and the slack
/// (`ListColumnWidth.pinnedBounds`, #1716): 320 to 491 pt in the Duo's
/// 867 pt split. The floor follows the ceiling down, and the reader's floor
/// follows what is left (`pinnedReaderFloor`, #2106).
struct ListColumnPolicy: Equatable, Sendable {
    /// The spec's floor, in a split wider than tall.
    static let wideMinimum: CGFloat = 320
    /// The width before the user sets one, where no crease offers one.
    static let defaultWidth: CGFloat = 360
    /// The range's ceiling until the split has been measured.
    static let unmeasuredMaximum: CGFloat = 640
    /// The divider's one animation: Reset, and the way back to the user's
    /// width after unfolding.
    static var dividerAnimation: Animation { .snappy(duration: 0.28) }

    /// The split view's frame in the window, with the keyboard's region
    /// ignored so a docked keyboard cannot change its shape; `.zero` until it
    /// is measured.
    var split: CGRect
    /// Columns tiled before the list inside `split`: none in `SplitShell`,
    /// whose sidebar column has no width.
    var leadingColumnsWidth: CGFloat = 0
    /// The fold the column has applied (`ListColumnState.fold`).
    var fold: FoldState
    /// The window's division region, active or not (`\.foldDivision`).
    var division: CGRect?
    /// The width the user left this list at in this window.
    var stored: CGFloat?
    /// The width of a drag in progress on this list.
    var live: CGFloat?

    var isMeasured: Bool { split.width > 0 }

    /// The width the list and the reader share.
    var available: CGFloat { max(0, split.width - leadingColumnsWidth) }

    /// The list's leading edge in the window.
    var listLeadingEdge: CGFloat { split.minX + leadingColumnsWidth }

    var isWide: Bool { split.width > split.height }

    var bounds: ClosedRange<CGFloat> {
        let floor = isWide ? Self.wideMinimum : ListColumnWidth.minimum
        guard isMeasured else { return floor...Self.unmeasuredMaximum }
        let range = ListColumnWidth.pinnedBounds(splitWidth: available, minimumWidth: floor)
        return range.minimum...range.maximum
    }

    func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    /// The width that ends the list at a vertical band's leading edge, when
    /// the range can seat it.
    func width(endingAt band: CGRect?) -> CGFloat? {
        guard isMeasured, case .vertical = FoldState(region: band), let band else { return nil }
        let width = band.minX - listLeadingEdge
        return bounds.contains(width) ? width : nil
    }

    /// The width a book fold pins the list to.
    var pin: CGFloat? {
        guard case .vertical(let crease) = fold else { return nil }
        return width(endingAt: crease)
    }

    /// The width that puts the list at the crease while the device lies flat.
    var foldLine: CGFloat? { width(endingAt: division) }

    /// Whether the range leaves the handle anywhere to go.
    var hasTravel: Bool { bounds.upperBound - bounds.lowerBound >= 1 }

    /// The handle shows only with no active fold — none on a book crease, and
    /// in laptop pose its centred grip would sit on the crease — and only
    /// where it can move the list.
    var handleIsShown: Bool { !fold.isFolded && hasTravel }

    var width: CGFloat {
        if let pin { return pin }
        if handleIsShown, let live { return clamped(live) }
        if let stored { return clamped(stored) }
        return foldLine ?? clamped(Self.defaultWidth)
    }

    /// The floor the reader declares beside `width`.
    var readerFloor: CGFloat {
        ListColumnWidth.pinnedReaderFloor(splitWidth: isMeasured ? available : 0, listWidth: width)
    }

    /// Whether there is a width of the user's to clear.
    var canReset: Bool { handleIsShown && stored != nil }

    var resetTitle: String { foldLine == nil ? "Reset Width" : "Reset to Fold" }

    /// A stored scene value as a width; 0, the missing-key default, is none.
    static func storedWidth(_ raw: Double) -> CGFloat? {
        raw.isFinite && raw > 0 ? CGFloat(raw) : nil
    }

    /// Whether leaving the `applied` fold for `new` takes the list back to
    /// its own width in the divider's one animation: an unfold, where the
    /// window's crease still runs top to bottom. A rotation (the division
    /// turns horizontal) or a close (it goes) moves the list with the
    /// window, and Reduce Motion moves it without one.
    static func unfoldAnimates(
        from applied: FoldState,
        to new: FoldState,
        division: CGRect?,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion, case .vertical = applied, new == .none,
              case .vertical = FoldState(region: division) else { return false }
        return true
    }
}
