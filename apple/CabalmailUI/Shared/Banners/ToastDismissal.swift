import CoreGraphics

/// The rules a status banner's dismissal follows: what counts as a dismissing
/// swipe, and how far the close button sits from whatever else the banner
/// offers to tap.
///
/// Issue #1426: the launch resume offer covered the filter pills and the top
/// of the first message row, and the user had no way to get rid of it — it
/// cleared itself after ten seconds and nothing else would. Waiting is not a
/// dismissal; the ask is for the action to exist.
///
/// The swipe is direction-agnostic on purpose. The report asked for a swipe
/// *up* because the banner hung from the top; the banner now hangs from the
/// bottom, where up is the wrong direction and down is the natural one — and
/// a user who guesses wrong on a control whose whole point is "get this out of
/// my way" has been failed twice. Any direction dismisses, which is also what
/// @mossy-dev asked for on the thread.
enum ToastDismissal {
    /// How far a drag must travel before it dismisses. Short enough to feel
    /// like a flick, long enough that a tap that slides a little does not
    /// throw the banner away while the user is reaching for `Resume`.
    static let swipeThreshold: CGFloat = 24

    /// Whether a finished drag dismisses the banner.
    static func dismisses(translation: CGSize) -> Bool {
        max(abs(translation.width), abs(translation.height)) >= swipeThreshold
    }

    /// Extra gap in front of the close button. @darth-sipid asked for enough
    /// distance between the close control and any other affordance — the
    /// trailing action is `Copy` on the address banners and `Resume` here, and
    /// hitting either by mistake is a navigation or a pasteboard write the
    /// user did not ask for. With no action button there is nothing to be
    /// confused with, so the banner's own spacing is enough.
    static func closeButtonLeadingGap(hasAction: Bool) -> CGFloat {
        hasAction ? 16 : 0
    }
}
