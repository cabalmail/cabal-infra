import Foundation

/// How a folder row's icon is coloured for its selection state.
///
/// A pure rule rather than an inline `if` in `FolderListView`, the way
/// `FolderNameTint` and `FolderSectionDisclosure` are.
///
/// The sibling of `FolderNameTint`, and it exists for the same reason: a
/// row's foreground may not be pinned to a colour picked for a selection
/// fill the platform is free to draw differently. `iconForeground` pinned
/// `Color.white` on the touch platforms because "iPadOS sidebar selection
/// paints the row in the accent color" — measured false on iPadOS 26.5
/// (#1318). What that fill is, on the two states a selected folder row is
/// actually drawn in:
///
/// * the unemphasized light grey `(209, 209, 214)`, on whichever of the two
///   rows for the selected path the list decides to fill — white measures
///   **1.52:1** there, under even the 3:1 WCAG floor for non-text UI;
/// * *no fill at all*, on the other row (the "All folders" section renders a
///   second row for the already-selected path) — white on white is
///   **1.00:1**, i.e. the icon is simply not drawn.
///
/// Pinning the brand accent instead — what macOS shipped, and the obvious
/// other candidate — clears both of those (4.68:1 and 7.12:1) and loses the
/// third state: an *emphasized* selection paints the system accent, against
/// which the brand's dark green computes to 1.77:1 (macOS's default blue;
/// the user picks that colour, so it isn't ours to budget for). Every pinned
/// colour loses somewhere, which is the whole argument for inheriting.
enum FolderIconTint: Equatable {
    /// No override — the row's own hierarchical foreground, which the
    /// platform inverts to suit whatever fill it ended up drawing.
    case inherited
    /// The brand accent from the asset catalog, marking an unselected row.
    case accent

    static func tint(isSelected: Bool) -> Self {
        isSelected ? .inherited : .accent
    }
}
