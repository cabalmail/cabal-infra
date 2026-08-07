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
}
