import CoreGraphics
import Foundation

/// Whether the iPad split must be built again because UIKit chose its column
/// layout against a width the window had already left.
///
/// Zooming a window back from compact lays the split view out at an
/// intermediate width — 534 pt inside an 834 pt window, measured on iPadOS
/// 27 — and the real width arrives about 240 ms later. The narrow pass is
/// the split view's alone: a plain view wrapped around it measures the
/// window's full width throughout. At 534 the pinned list column and the
/// reader's floor cannot sit side by side, so UIKit gives up tiling and
/// floats the list over a reader as wide as the window, and it does not
/// revisit that once the split reaches its real width — leaving the list
/// floating over a dimmed full-width reader until the next size transition
/// (#1988). Giving the split a new identity at the first layout wide enough
/// to tile is what makes it decide again.
///
/// One shot per shell: only the *first* layout can arm the policy, and it
/// bumps `generation` at most once. A later narrow layout is a resize the
/// shell swap handles (`SectionLayoutPolicy`), not a decision made against
/// stale bounds, and rebuilding the split on one would throw the reader away
/// mid-drag.
struct SplitRetilePolicy: Equatable {
    /// The split's identity. Bumped once, when a too-narrow first layout is
    /// followed by one wide enough to tile.
    private(set) var generation = 0

    private enum Phase: Equatable {
        /// No layout measured yet.
        case awaitingFirstLayout
        /// The first layout was too narrow to tile: the next wide one rebuilds.
        case armed
        /// Either the first layout was wide enough, or the rebuild has been asked for.
        case settled
    }

    private var phase: Phase = .awaitingFirstLayout

    /// Whether a rebuild is still to come: the first layout was too narrow
    /// and no wide one has followed it.
    var isArmed: Bool { phase == .armed }

    /// Feeds the split view's own measured width in. A zero or negative
    /// width is not a measurement (`onGeometryChange` reports one before the
    /// split has bounds) and changes nothing.
    mutating func recordLayout(width: CGFloat) {
        guard width > 0 else { return }
        let tiles = width >= SectionLayoutPolicy.regularWidthFloor
        switch phase {
        case .awaitingFirstLayout:
            phase = tiles ? .settled : .armed
        case .armed:
            guard tiles else { return }
            generation += 1
            phase = .settled
        case .settled:
            return
        }
    }
}
