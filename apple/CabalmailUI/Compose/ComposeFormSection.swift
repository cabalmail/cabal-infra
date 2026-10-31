/// The order of the grouped-`Form` compose sections (iOS / iPadOS /
/// visionOS). A pure list rather than a literal run of `Section`s so the
/// one rule that governs it can be tested — `ComposeView`'s layout isn't
/// reachable from a unit test, this is.
///
/// The rule: every section the user has to see or act on renders ABOVE
/// `.message`. The body editor is greedy, so anything after it starts
/// below the fold, and the `WKWebView` swallows the pan that would scroll
/// down to it — a section placed there is invisible and unreachable, not
/// merely off screen. That cost a send-blocking error banner (#812) and
/// the staged-attachment list (#858).
///
/// Laptop pose is the one exception (`order(inLaptop:)`): the body leads,
/// held above the fold at a fixed height (`ComposeLaptopPolicy.bodyFrame`),
/// so it isn't greedy, and the fields follow below the fold, panned on
/// their own rows rather than on the web view. Both orders hold the same
/// five ids, so a fold moves sections and rebuilds none: the editor keeps
/// its web view, caret and undo (measured, 2026-10-31).
///
/// The error banner is deliberately absent from the list. A scrolling
/// section can't carry it: the form is already scrolled down to clear the
/// keyboard when the error appears, and nothing scrolls it back, so the
/// banner laid out 27pt ABOVE the top of the sheet, behind the toolbar —
/// present in the accessibility tree, invisible to the user (#938). It is
/// pinned above the scroll instead, in `ComposeView.composeErrorBanner`.
enum ComposeFormSection: CaseIterable {
    case from
    case recipients
    case subject
    case attachments
    case message

    /// The sections in drawn order: the body first in laptop pose, the case
    /// order everywhere else.
    static func order(inLaptop: Bool) -> [ComposeFormSection] {
        inLaptop ? [.message, .from, .recipients, .subject, .attachments] : allCases
    }
}
