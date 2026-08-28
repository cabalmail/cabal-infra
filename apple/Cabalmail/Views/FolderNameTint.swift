import Foundation

/// How a folder row's name is coloured for its unread state.
///
/// A pure rule rather than an inline `if` in `FolderListView` so it can be
/// tested directly, the way `FolderSectionDisclosure` and
/// `CompactColumnPolicy` are.
///
/// Colouring the name by unread state (#1294) cost most of the sidebar's
/// contrast, measured on iPadOS 26.5 and macOS (#1297). Two of the three
/// cases here exist to say what the rule must *not* do:
///
/// * **A selected row keeps the platform's own foreground.** The selection
///   fill is the platform's to choose and it varies more than a pinned
///   colour can survive. iPadOS draws an unemphasized light grey
///   `(209, 209, 214)` whenever the sidebar column isn't focused — which is
///   nearly always under touch, not the accent tint the original comment
///   assumed — and it draws *no* fill at all behind the second row the
///   "All folders" section renders for the already-selected path. A pinned
///   white measured 1.52:1 on the first and 1.00:1, i.e. invisible, on the
///   second.
/// * **A caught-up row dims by a fixed fraction of the label colour, not
///   by `.secondary`.** `.secondary`'s alpha is the OS's to pick and it is
///   not picked for contrast: the same code resolves to 50% black on
///   iPadOS (4.00:1 over the sidebar's white, under the 4.5:1 WCAG AA floor
///   for normal text) and to roughly 46% on macOS 27 (2.90–3.31:1 over the
///   sidebar material) while landing near 59% on macOS 26. A fraction we
///   choose composites predictably on all three.
enum FolderNameTint: Equatable {
    /// No override — whatever foreground the row is already drawing in.
    /// Hierarchical, so it follows the selection fill rather than guessing
    /// at it.
    case inherited
    /// The brand accent, marking a folder with unread mail.
    case unread
    /// The label colour kept at `dimmedOpacity`, marking a caught-up folder.
    case caughtUp

    /// Fraction of the label colour a caught-up folder's name keeps.
    ///
    /// 0.7 rather than something nearer the AA floor because macOS does not
    /// composite this source-over. Over the sidebar's vibrancy material an
    /// opacity lands at about `macOSVibrancyDiscount` of the fraction asked
    /// for, so the honest budget is the discounted fraction, not the nominal
    /// one. The first cut at 0.6 measured 4.04:1 on macOS 26.6 — *below* the
    /// 5.29:1 `.secondary` was already getting there, i.e. a fix that
    /// regressed the one platform the reported rule happened to suit. 0.7
    /// measures 5.35:1 there and 8.59:1 on iPadOS, where the discount does
    /// not apply.
    static let dimmedOpacity = 0.7

    /// What fraction of a nominal opacity actually reaches the pixel when
    /// the label sits on macOS's sidebar material.
    ///
    /// Measured on macOS 26.6 over background `(236, 240, 243)`: a nominal
    /// 0.6 composited as 0.51 and a nominal 0.7 as 0.59, both within 0.01 of
    /// this factor. Recorded rather than worked around — no API reports it,
    /// so anything reasoning about this rule's contrast has to apply it by
    /// hand.
    static let macOSVibrancyDiscount = 0.85

    static func tint(hasUnread: Bool, isSelected: Bool) -> Self {
        // Selection wins over the unread signal: an unread folder that is
        // also the selected one was the 1.52:1 row, and its unread state is
        // still carried by the count badge beside the name.
        if isSelected { return .inherited }
        return hasUnread ? .unread : .caughtUp
    }
}
