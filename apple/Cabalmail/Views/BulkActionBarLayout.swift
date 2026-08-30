import Foundation

/// How much of the bulk action bar fits at the width it is drawn in — the
/// ladder `bulkActionBar` hands to `ViewThatFits`, widest first.
///
/// The bar lives inside the message-list column, not the window, and on
/// macOS that column is 220 pt until the window grows past ~1000 pt wide.
/// At 220 pt the full bar does not fit, and left to itself SwiftUI resolved
/// the squeeze by hyphenating every caption — "Ar-chive", "Rea d", a
/// four-line "2 se-lect-ed" (#1343). So the bar sheds whole elements
/// instead of breaking words: the selection count first (the reader pane
/// says "N Messages Selected" beside it, and every button's accessibility
/// label carries the count), then the captions, which leaves the glyph row
/// every touch and pointer layout can still fit.
enum BulkActionBarLayout: CaseIterable {
    /// Selection count plus a captioned button per action. What iPhone and
    /// a wide message-list column show, unchanged.
    case full
    /// Captioned buttons, no count.
    case captionsOnly
    /// Glyph-only buttons, no count — the narrowest the bar goes.
    case glyphsOnly

    var showsCount: Bool { self == .full }

    var showsCaptions: Bool { self != .glyphsOnly }
}
