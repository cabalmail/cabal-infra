import CoreGraphics

/// Whether a fold crosses this window, and where: the one fold signal the
/// layout reads (the iPhone Duo spec's "only extra signal is an active fold
/// region").
///
/// A fold is iPhone Duo held partly open, in book pose (the crease runs top
/// to bottom through a wide window) or laptop pose (it runs side to side
/// through a tall one). Those two poses draw the same window, with the same
/// size classes, as the device lying flat; the active fold region is the
/// only difference, so layout follows it and never a pose name, the device
/// or its idiom. Closing and opening the Duo is not a fold: it resizes the
/// window and swaps the shells (`SectionLayoutPolicy`). Flat, the division
/// region was measured inactive; whether one can be active on the closed
/// outer display is unmeasured (Apple's own page says both), and if one is,
/// it is a fold like any other here.
///
/// `FoldGeometry` publishes it to a main window as `\.foldState`, after the
/// settling and hinge hold in `FoldHold`. The crease is in the window's own
/// coordinates (SwiftUI's `.global` space), never a physical half of the
/// device, so a window turned upside down reads the crease where it
/// actually is.
enum FoldState: Equatable, Sendable {
    /// Nothing crosses the window: every display that does not fold, and the
    /// Duo flat or closed.
    case none
    /// The crease runs top to bottom, so the window's two pieces sit side by
    /// side (book pose).
    case vertical(crease: CGRect)
    /// The crease runs side to side, so the window's two pieces are stacked
    /// (laptop pose).
    case horizontal(crease: CGRect)

    /// The fold an active division region describes, from its frame: taller
    /// than wide is a vertical crease, wider than tall a horizontal one, as
    /// Apple's own reading of the region goes ("iPhone Duo has one fold").
    /// No region, an empty one or a square one is no fold.
    init(region: CGRect?) {
        guard let region, !region.isEmpty, region.width != region.height else {
            self = .none
            return
        }
        self = region.height > region.width ? .vertical(crease: region) : .horizontal(crease: region)
    }

    /// The crease, in window coordinates; nil when nothing is folded.
    var crease: CGRect? {
        switch self {
        case .none: return nil
        case .vertical(let crease), .horizontal(let crease): return crease
        }
    }

    var isFolded: Bool { crease != nil }

    /// The crease in a view's own coordinates, given where that view sits in
    /// the window (its `frame(in: .global)`); nil when nothing is folded.
    /// The result can lie partly or wholly outside the view's bounds.
    func crease(inViewAt frameInWindow: CGRect) -> CGRect? {
        crease?.offsetBy(dx: -frameInWindow.minX, dy: -frameInWindow.minY)
    }
}

/// A view's bounds less the fold: the pieces something floating over it may
/// sit in, so nothing Cabalmail draws lands on the crease.
///
/// The fold rule in the Duo spec places a floating element in "the piece
/// that belongs to the column that raised it": the reader's piece for
/// something the reader raised, the list's for the list's, and on a
/// horizontal fold, buttons below and status above. This type is only the
/// geometry; who goes where is the caller's rule.
enum FoldPieces: Equatable, Sendable {
    /// No fold crosses the bounds.
    case whole(CGRect)
    /// A vertical crease crosses them: the piece before it along the x axis
    /// (the leading one, in SwiftUI's coordinates) and the piece after it.
    case sideBySide(leading: CGRect, trailing: CGRect)
    /// A horizontal crease crosses them: the piece above it and the piece
    /// below it.
    case stacked(top: CGRect, bottom: CGRect)

    /// - Parameters:
    ///   - bounds: the view's bounds, in its own coordinates.
    ///   - fold: the window's fold.
    ///   - frameInWindow: where the view sits in the window, to bring the
    ///     crease into the view's coordinates.
    init(bounds: CGRect, fold: FoldState, frameInWindow: CGRect) {
        guard let crease = fold.crease(inViewAt: frameInWindow),
              crease.intersects(bounds) else {
            self = .whole(bounds)
            return
        }
        switch fold {
        case .vertical:
            // A crease that only clips one edge leaves a single piece, so the
            // empty side is never offered to anything.
            guard crease.minX > bounds.minX, crease.maxX < bounds.maxX else {
                self = .whole(Self.remainder(of: bounds, beside: crease, horizontally: true))
                return
            }
            self = .sideBySide(
                leading: CGRect(x: bounds.minX, y: bounds.minY,
                                width: crease.minX - bounds.minX, height: bounds.height),
                trailing: CGRect(x: crease.maxX, y: bounds.minY,
                                 width: bounds.maxX - crease.maxX, height: bounds.height)
            )
        case .horizontal:
            guard crease.minY > bounds.minY, crease.maxY < bounds.maxY else {
                self = .whole(Self.remainder(of: bounds, beside: crease, horizontally: false))
                return
            }
            self = .stacked(
                top: CGRect(x: bounds.minX, y: bounds.minY,
                            width: bounds.width, height: crease.minY - bounds.minY),
                bottom: CGRect(x: bounds.minX, y: crease.maxY,
                               width: bounds.width, height: bounds.maxY - crease.maxY)
            )
        case .none:
            self = .whole(bounds)
        }
    }

    /// What is left of `bounds` once a crease that covers one of its edges
    /// is taken off: the larger side, or nothing if the crease covers it all.
    private static func remainder(of bounds: CGRect, beside crease: CGRect, horizontally: Bool) -> CGRect {
        if horizontally {
            let before = CGRect(x: bounds.minX, y: bounds.minY,
                                width: max(0, crease.minX - bounds.minX), height: bounds.height)
            let after = CGRect(x: crease.maxX, y: bounds.minY,
                               width: max(0, bounds.maxX - crease.maxX), height: bounds.height)
            return before.width >= after.width ? before : after
        }
        let above = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: max(0, crease.minY - bounds.minY))
        let below = CGRect(x: bounds.minX, y: crease.maxY,
                           width: bounds.width, height: max(0, bounds.maxY - crease.maxY))
        return above.height >= below.height ? above : below
    }
}
