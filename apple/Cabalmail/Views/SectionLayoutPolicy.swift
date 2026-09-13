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
}
