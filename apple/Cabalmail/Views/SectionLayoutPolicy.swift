import Foundation

/// Which section layout the signed-in root should draw on iOS: the compact
/// bottom tab bar (Mail / Feeds / Addresses / Settings / Search) or the
/// iPad single-sidebar split. A pure rule rather than an inline `if` so it can
/// be tested — `SignedInRootView` reads the environment, this doesn't.
///
/// The decision is by **idiom first, size class second**. It used to be size
/// class alone, and that is a rotation bug on the Plus / Max iPhones: they
/// report a *regular* horizontal size class in landscape, so turning the phone
/// swapped the whole tab tree for the iPad split view. The two layouts are
/// separate view trees with separate `@State` selections, so the rotation
/// threw away the Feeds tab and whatever was open in it, and landed the user
/// on the mail split's launch landing — the INBOX. Rotating back rebuilt the
/// tabs from scratch, at the resume session's landing rather than where the
/// user had been. An iPhone never draws the iPad layout: it has no room for a
/// sidebar-plus-list-plus-reader split at any orientation, and the tab bar is
/// the only place its Feeds section lives.
///
/// iPad keeps the size-class branch: a regular-width iPad gets the split, and
/// a narrow multitasking window (compact) gets the tabs.
///
/// Keeping the *section* layout on the tabs turned out to be only half of the
/// rotation story. Everything inside the tabs still read the raw size class,
/// and the Mail tab's `NavigationSplitView` expanded into tiled columns
/// whenever a Plus / Max went landscape, then collapsed again on the way
/// back. That expand/collapse cycle is where the "wider screen" bugs live:
/// after it, the collapsed split could stop pushing the reader for a tapped
/// row (the message loaded into a detail column that wasn't on screen), and
/// the addresses inspector hung on the split — a trailing column at regular
/// width, a sheet at compact — could surface as a full-height sheet over the
/// tab bar with no way out but a force quit. So the tab tree also pins the
/// *environment* size class to compact on a phone (`pinsCompactWidth`): the
/// split view never expands, the inspector never changes presentation, and
/// every size-class read below (list drag-to-folder, the reader's action
/// bar) sees the same answer in both orientations. The cost is the two-column
/// list-plus-reader a Max used to show in landscape; the phone now reads
/// like a phone in every orientation.
enum SectionLayoutPolicy {
    enum Layout: Equatable {
        /// `SignedInRootView.compactTabs`: the bottom tab bar.
        case compactTabs
        /// `MailRootView` alone, with the settings gear and sheet.
        case regularSplit
    }

    /// - Parameters:
    ///   - isPhone: `UIDevice.current.userInterfaceIdiom == .phone`.
    ///   - isCompactWidth: `horizontalSizeClass == .compact`.
    static func layout(isPhone: Bool, isCompactWidth: Bool) -> Layout {
        if isPhone || isCompactWidth { return .compactTabs }
        return .regularSplit
    }

    /// Whether the compact tab tree should override the environment's
    /// horizontal size class to `.compact` for everything beneath it. True on
    /// a phone, whose landscape size class is the only source of a regular
    /// width there; an iPad in narrow multitasking is already compact and
    /// switches to the split layout (a different tree) when it widens, so it
    /// needs no override.
    ///
    /// - Parameter isPhone: `UIDevice.current.userInterfaceIdiom == .phone`.
    static func pinsCompactWidth(isPhone: Bool) -> Bool {
        isPhone
    }
}
