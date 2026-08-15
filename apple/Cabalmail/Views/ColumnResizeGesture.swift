import CoreGraphics

/// Which touches near the message-list column's trailing edge belong to the
/// column-resize handle.
///
/// Split out of `ColumnResizeHandle` because the handle used to answer this
/// question by *being* a hit-testable strip: a 22pt transparent rectangle
/// carrying the drag gesture. That conflates "did the touch land on the band?"
/// with "is the touch a resize?", and SwiftUI does not forward a touch to the
/// sibling underneath once a failed gesture has claimed it — so a tap on the
/// trailing 22pt of a message row was silently swallowed, the row never saw it,
/// and the same band ate the start of a trailing row swipe (#1075).
///
/// The rule is the same either way; stating it as a value lets the view keep
/// the band non-interactive and hand only the touches that are genuinely
/// resizes to a UIKit recognizer that sits above the rows.
enum ColumnResizeGesture {
    /// Width of the grab band inside the column's trailing edge.
    ///
    /// Forgiving enough to hit with a finger on the first try, which is what
    /// #1052/#1059 settled on and what the band has always been. It costs the
    /// rows nothing now that landing in it is no longer the same as claiming it.
    static let grabWidth: CGFloat = 22

    /// Whether a touch at `point` — in the band view's own coordinate space,
    /// whose `bounds` are the band — is the handle's to consider at all.
    ///
    /// Touches outside the band are rejected before the recognizer ever sees
    /// them, so the rest of the column behaves as though no handle existed.
    static func acceptsTouch(at point: CGPoint, band: CGRect) -> Bool {
        band.contains(point)
    }

    /// Whether an accepted touch's opening movement is a resize rather than
    /// something the view underneath should keep.
    ///
    /// Horizontal-dominant only: a vertical drag that starts in the band is the
    /// user scrolling the message list near its edge, and a tap has no
    /// translation at all. Both fail here, the recognizer never begins, and the
    /// touch stays with the row.
    static func beginsResize(translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height)
    }

    /// Column width for a drag of `translation` from the width captured when
    /// the drag began, clamped to the column's allowed range.
    ///
    /// Against a fixed anchor rather than the live width: the handle is pinned
    /// to the trailing edge, so each frame's resize moves the handle itself,
    /// and compounding per-frame deltas made the divider track the finger at
    /// roughly half speed (#1059). The caller reads the translation in the
    /// window's space, which the resize does not move.
    static func resizedWidth(anchor: CGFloat,
                             translation: CGFloat,
                             minWidth: CGFloat,
                             maxWidth: CGFloat) -> CGFloat {
        min(max(anchor + translation, minWidth), maxWidth)
    }
}
