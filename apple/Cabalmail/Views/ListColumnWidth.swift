import Foundation
import SwiftUI

/// Width policy for the macOS message-list (content) column.
///
/// The column declared no width of its own, so macOS 27 sized it from the
/// list's own greedy ideal and made the *neighbours* pay for it: measured at
/// launch, the sidebar sat at exactly `SidebarColumnWidth.minimum` (180pt, its
/// declared floor — the only thing protecting it) while the reading pane, which
/// declares no floor at all, absorbed every subsequent resize on its own. The
/// list stayed frozen at its launch width (658pt in a 1500pt window, 838pt in a
/// 2900pt one) and the reader shrank without limit — 60pt in a 900pt window.
/// A reader that narrow reads as broken rather than cramped: selecting a message
/// visibly does nothing, because there is nowhere for the message to appear.
///
/// Bounding the column fixes both halves. The `max` is the lever that bites on
/// 27 — the greedy column stops where it is told to — and the `min` is what lets
/// the split take width back from the list as the window shrinks, instead of
/// only from the reader. `ideal` is stated for the OS that honours it; 27 does
/// not (the sidebar's own `ideal` is ignored the same way, which is why it was
/// measured sitting at its floor).
enum ListColumnWidth {
    /// Narrow enough to hand the window back to the reading pane, wide enough
    /// that a row's sender line and trailing date still share one line.
    static let minimum: CGFloat = 300
    /// Launch width: two comfortable lines of subject and sender without
    /// claiming the half of the window the reader wants.
    static let ideal: CGFloat = 420
    /// Width the reading pane needs before it can show a message rather than a
    /// column of one-word lines.
    static let readerFloor: CGFloat = 360
    /// Floor the column may be squeezed to in a window too narrow to seat all
    /// three columns at their preferred widths. Below `minimum` a row's sender
    /// and date stop sharing a line, which is why `minimum` is the floor
    /// wherever the window can afford it — but a cramped window has to take the
    /// width from somewhere, and taking it from the list is what leaves the
    /// reader able to render a message at all.
    static let squeezedMinimum: CGFloat = 220
    /// The narrowest resize range worth handing the divider.
    ///
    /// A column whose floor equals its ceiling has no travel, and the split view
    /// does not then leave the divider alone: the drag silently retargets the
    /// *sidebar*, which grows to its own maximum and takes the width out of the
    /// reading pane. So the drag a user makes to give the reader room was taking
    /// room away from it (#1014).
    static let minimumTravel: CGFloat = 60
    /// The largest share of the window the list may claim.
    ///
    /// This, not `ideal`, is what decides the split on macOS 27: measured there,
    /// the content column takes everything up to its maximum while the sidebar
    /// and reader sit at their floors rather than their preferred widths, so a
    /// preferred width for the list has nothing to push against. Capping the
    /// share is what keeps a launch balanced — and it costs the user only the
    /// right to drag the list past the point where the reader stops being the
    /// point of the window.
    static let maximumWindowShare: CGFloat = 0.45

    /// Resize range for the column in a split of `splitWidth`.
    ///
    /// The ceiling is the list's share of the window, and never more than leaves
    /// the sidebar its launch width and the reader its floor. The floor is
    /// `minimum` wherever the window can seat that and still leave the divider
    /// somewhere to travel; in a window too narrow for all three (below about
    /// 980pt with the shipped constants) the list gives ground instead —
    /// `squeezedMinimum` rather than a ceiling raised into the reader's floor,
    /// because the reader is the point of the window (#984).
    ///
    /// The range is never empty. That is the whole of #1014: the old form
    /// clamped the ceiling up to `minimum`, so at and below ~920pt floor and
    /// ceiling met, the column froze, and the drag went to the sidebar instead
    /// — costing the reading pane the width the drag was meant to give it.
    ///
    /// Zero, the pre-layout measurement, resolves to `ideal` so the first layout
    /// doesn't pin the column to its floor and flick it wider a frame later.
    static func bounds(splitWidth: CGFloat,
                       sidebarWidth: CGFloat) -> (minimum: CGFloat, maximum: CGFloat) {
        guard splitWidth > 0 else { return (minimum, ideal) }
        let leavingReaderItsFloor = splitWidth - sidebarWidth - readerFloor
        let ceiling = min(splitWidth * maximumWindowShare, leavingReaderItsFloor)
        let floor = min(minimum, max(squeezedMinimum, ceiling - minimumTravel))
        return (floor, max(ceiling, floor + minimumTravel))
    }
}

#if os(macOS)
/// Opens the message-list column at `ListColumnWidth.ideal` and bounds it so
/// the reading pane keeps a usable width. `min`/`ideal`/`max` rather than a
/// pinned width: the pinned form takes the native divider away, and the divider
/// is how a Mac user expects to resize a column.
private struct ListColumnWidthPolicy: ViewModifier {
    /// Live width of the whole split view. Only the `max` is derived from it,
    /// and a maximum merely clamps — unlike a preferred width it can't pull the
    /// column toward itself, so feeding the measurement back doesn't oscillate.
    let splitWidth: CGFloat

    func body(content: Content) -> some View {
        let bounds = ListColumnWidth.bounds(
            splitWidth: splitWidth,
            sidebarWidth: SidebarColumnWidth.ideal
        )
        return content
            .navigationSplitViewColumnWidth(
                min: bounds.minimum,
                ideal: ListColumnWidth.ideal,
                max: bounds.maximum
            )
    }
}
#endif

extension View {
    /// macOS: see `ListColumnWidthPolicy`. Every other platform sizes the list
    /// column elsewhere — regular-width iPad and visionOS pin it to the width
    /// the drag handle persists (`resizableContentColumn`), compact iPhone
    /// collapses the split to a stack — so this passes through.
    @ViewBuilder
    func listColumnWidthPolicy(splitWidth: CGFloat) -> some View {
        #if os(macOS)
        modifier(ListColumnWidthPolicy(splitWidth: splitWidth))
        #else
        self
        #endif
    }
}
