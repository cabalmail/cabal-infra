import SwiftUI

/// Emphasis policy for the count that trails each filter pill's label.
///
/// The count is a detail next to its label, and `.secondary` reads that way on
/// iPhone, iPad and the Mac, where the filter bar has an opaque window behind
/// it. visionOS composites the same bar over the room instead: `.secondary` is
/// a partly transparent fill of the foreground colour, and over passthrough it
/// has nothing to sit against — the numbers disappear and the row reads as a
/// bare "All / Unread / Flagged" (#993). Reproduced on the visionOS 26.5
/// simulator as well as 27, so it is the platform's compositing model rather
/// than a 27 regression.
enum FilterPillCountStyle {

    /// Whether this platform draws app windows over passthrough rather than
    /// over an opaque surface.
    static let overPassthroughGlass: Bool = {
        #if os(visionOS)
        return true
        #else
        return false
        #endif
    }()

    /// How prominently the count is drawn.
    enum Emphasis: Equatable {
        case secondary
        case primary
    }

    /// The pill count's emphasis: subordinate to its label wherever the bar has
    /// something opaque behind it, and the label's own full-strength foreground
    /// on glass, which is the weakest fill that still renders there.
    static func countEmphasis(overGlass: Bool = overPassthroughGlass) -> Emphasis {
        overGlass ? .primary : .secondary
    }
}

extension FilterPillCountStyle.Emphasis {
    var shapeStyle: AnyShapeStyle {
        switch self {
        case .secondary: return AnyShapeStyle(.secondary)
        case .primary:   return AnyShapeStyle(.primary)
        }
    }
}
