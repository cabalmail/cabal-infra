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
/// only from the reader.
///
/// The column opens at the width it was last left at (`resolved(stored:)`), or
/// at `ideal` until the user resizes it. macOS 27 honours that preferred width,
/// and the sidebar's, unless AppKit restores its own saved divider positions
/// over them, which it no longer gets to do (`SplitViewAutosave`). The note
/// that used to stand here, that 27 ignores `ideal`, was measured with those
/// restored positions in place.
enum ListColumnWidth {
    /// `@AppStorage`/`UserDefaults` key holding the width the user last left
    /// the column at. Zero (the missing-key default) means "never resized" and
    /// resolves to `ideal`. Not the iPad layout's
    /// `cabalmail.layout.listColumnWidth`: that one is the width the column is
    /// pinned to, and `SplitShell` observes it, so sharing it would re-render
    /// the whole root on every point of a divider drag here.
    static let storageKey = "cabalmail.layout.macListColumnWidth"

    /// Narrow enough to hand the window back to the reading pane, wide enough
    /// that a row's sender line and trailing date still share one line.
    static let minimum: CGFloat = 300
    /// Launch width until the user resizes the column: two comfortable lines of
    /// subject and sender without claiming the half of the window the reader
    /// wants.
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
    /// The largest share of the window the list may claim, whatever width it
    /// opens at or is dragged to. It costs the user only the right to drag the
    /// list past the point where the reader stops being the point of the
    /// window.
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
    /// Zero, the pre-layout measurement, resolves to a range ending at
    /// `launchWidth`, the width the column opens at. The first layout is the
    /// one that seats the column, and the real range only clamps it afterwards:
    /// a floor there would open it narrow and flick it wider a frame later, and
    /// a ceiling short of a remembered width would cut that width short for
    /// good.
    static func bounds(splitWidth: CGFloat,
                       sidebarWidth: CGFloat,
                       launchWidth: CGFloat = ideal) -> (minimum: CGFloat, maximum: CGFloat) {
        guard splitWidth > 0 else { return (min(minimum, launchWidth), launchWidth) }
        let leavingReaderItsFloor = splitWidth - sidebarWidth - readerFloor
        let ceiling = min(splitWidth * maximumWindowShare, leavingReaderItsFloor)
        let floor = min(minimum, max(squeezedMinimum, ceiling - minimumTravel))
        return (floor, max(ceiling, floor + minimumTravel))
    }

    /// The width to open at: the one the user left the column at, else
    /// `ideal`. Not fitted to a window here — the range depends on the window,
    /// and `bounds` clamps the column into it once the split is measured — but
    /// never below the narrowest range `bounds` hands out, which no measured
    /// width can be.
    static func resolved(stored: Double) -> CGFloat {
        guard stored > 0 else { return ideal }
        return max(CGFloat(stored), squeezedMinimum)
    }

    /// Whether a width measured off the column is one to remember in place of
    /// `stored`.
    ///
    /// Only once the split has been measured: before that, `bounds` is a guess.
    /// Only inside the range the column was given, because a column being
    /// re-seated reports passing widths that are not its own — 0 and 91pt were
    /// measured mid-way through a window resize that clamped it. And only
    /// beyond the rounding slack the sidebar allows
    /// (`SidebarColumnWidth.persistEpsilon`).
    ///
    /// Not, either, a width the range is holding the column at short of the one
    /// remembered. That is the window, or the addresses inspector opening
    /// beside the list, squeezing the column rather than the user resizing it,
    /// and the split hands the width back as soon as there is room: measured on
    /// macOS 27, a 500pt list held at 400 while the inspector was open went
    /// back to 500 when it closed. Remembering the 400 brought the list back at
    /// 400 on the next launch, into a window with room for 500. A drag that
    /// takes the column to the edge of its range is still remembered; it
    /// starts from inside the range.
    static func shouldPersist(measured: CGFloat,
                              stored: Double,
                              splitWidth: CGFloat,
                              bounds: (minimum: CGFloat, maximum: CGFloat)) -> Bool {
        let slack = SidebarColumnWidth.persistEpsilon
        guard splitWidth > 0,
              measured >= bounds.minimum - slack,
              measured <= bounds.maximum + slack else { return false }
        let remembered = resolved(stored: stored)
        let heldAtCeiling = measured >= bounds.maximum - slack && remembered > bounds.maximum
        let heldAtFloor = measured <= bounds.minimum + slack && remembered < bounds.minimum
        guard !heldAtCeiling, !heldAtFloor else { return false }
        return abs(measured - remembered) > slack
    }

    /// Width the pinned column leaves over and above the reader's floor.
    ///
    /// Where the column is pinned to an exact width (regular-width iPad and
    /// visionOS — see `SplitShell.listColumn`) a ceiling of
    /// `splitWidth - readerFloor` makes the two constraints sum to exactly the
    /// window. UIKit resolves that fit at launch but not during a size
    /// transition: re-resolving it mid-resize, it gives up tiling and drops the
    /// primary column, leaving the reader's empty-state placeholder alone in a
    /// window with no control of any kind in it (#1716). Reserving slack means
    /// the fit is never exact, so there is nothing to give up on. 11pt was
    /// measured surviving the same transition that 0pt failed (#1716's width
    /// sweep, the 749pt row against the 700 and 725 ones); this is that value
    /// rounded up to the layout unit used elsewhere, and it costs the list at
    /// most 16pt in the band where the clamp bites at all.
    static let reservedSlack: CGFloat = 16

    /// Clamp range for a column pinned to an exact width in a split of
    /// `splitWidth`, with no sidebar column tiled beside it.
    ///
    /// The ceiling reserves `reservedSlack` beyond the reader's floor (above).
    /// The floor follows the ceiling down: a window too narrow to seat
    /// `minimum` alongside the reader's floor and that slack has to take the
    /// width from the list — `squeezedMinimum` for the same reason `bounds`
    /// does it (the reader is the point of the window) — because a floor left
    /// above the ceiling would pin the column wider than the window can seat
    /// and over-subscribe the split instead of merely filling it.
    static func pinnedBounds(splitWidth: CGFloat) -> (minimum: CGFloat, maximum: CGFloat) {
        let ceiling = max(squeezedMinimum, splitWidth - readerFloor - reservedSlack)
        return (min(minimum, ceiling), ceiling)
    }
}

#if os(macOS)
/// Opens the message-list column at the width it was last left at, bounds it
/// so the reading pane keeps a usable width, and persists the width it is
/// dragged to. `min`/`ideal`/`max` rather than a pinned width: the pinned form
/// takes the native divider away, and the divider is how a Mac user expects to
/// resize a column.
private struct ListColumnWidthPolicy: ViewModifier {
    /// Live width of the whole split view. Only the `max` is derived from it,
    /// and a maximum merely clamps — unlike a preferred width it can't pull the
    /// column toward itself, so feeding the measurement back doesn't oscillate.
    let splitWidth: CGFloat
    @AppStorage(ListColumnWidth.storageKey) private var stored: Double = 0
    /// Resolved from the store once, when the modifier is first created: only
    /// the first layout reads the preferred width, and the divider owns the
    /// column from there.
    @State private var launchWidth: CGFloat = ListColumnWidth.resolved(
        stored: UserDefaults.standard.double(forKey: ListColumnWidth.storageKey)
    )

    func body(content: Content) -> some View {
        let bounds = ListColumnWidth.bounds(
            splitWidth: splitWidth,
            sidebarWidth: SidebarColumnWidth.ideal,
            launchWidth: launchWidth
        )
        // The measurement goes under the width modifier, for the reason
        // `SidebarColumnWidthPolicy` records.
        return content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                guard ListColumnWidth.shouldPersist(
                    measured: width,
                    stored: stored,
                    splitWidth: splitWidth,
                    bounds: bounds
                ) else { return }
                stored = Double(width)
            }
            // AppKit's own saved divider positions would be restored over the
            // width opened at here, and wrongly (`SplitViewAutosave`).
            .background { SplitViewAutosaveDisabler() }
            .navigationSplitViewColumnWidth(
                min: bounds.minimum,
                ideal: launchWidth,
                max: bounds.maximum
            )
    }
}
#endif

extension View {
    /// macOS: see `ListColumnWidthPolicy`. Every other platform sizes the list
    /// column elsewhere — the iPad split pins it to the width the drag handle
    /// persists (`SplitShell.listColumn`), the tab layout collapses its split
    /// to a stack — so this passes through.
    ///
    /// On macOS it also carries the switch that turns off AppKit's autosave of
    /// the main window's split (`SplitViewAutosave`).
    @ViewBuilder
    func listColumnWidthPolicy(splitWidth: CGFloat) -> some View {
        #if os(macOS)
        modifier(ListColumnWidthPolicy(splitWidth: splitWidth))
        #else
        self
        #endif
    }
}
