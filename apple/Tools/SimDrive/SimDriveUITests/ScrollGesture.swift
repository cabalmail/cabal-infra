import CoreGraphics
import Foundation

/// The endpoint arithmetic behind the `scroll` verb, kept as a pure value so
/// the rule it enforces is testable without a simulator (#1188).
///
/// A synthesized press-and-drag only scrolls while both of its ends stay well
/// inside the scrollable thing the caller named. Endpoints scaled to the whole
/// WINDOW routinely miss, and what the stray end then does depends on what is
/// behind it: measured on iPadOS 26.5, a `dir:up` at the default amount pressed
/// 27 points below a Settings form sheet's top edge and DISMISSED the sheet;
/// measured on visionOS 26.5, the same default against the full-window Settings
/// list RESIZED the app window down to a strip. Both returned `ok:true` with a
/// plausible travel, so the failure was silent and read exactly like the
/// below-the-fold content being unreachable — the symptom `scroll` exists to
/// cure.
///
/// The cure is to stop spending the whole travel in one gesture. The requested
/// travel is kept, but it is spread over as many sweeps as it takes for every
/// endpoint to land in the middle fifth of the container, which is far enough
/// from the edges to clear whatever chrome lives there without having to know
/// what that chrome is.
///
/// This plans what the FINGER covers. Since #1193 it is an upper bound rather
/// than a script: each sweep is measured against the caller's element and
/// `ScrollFeedback` sizes the next one from what the last one achieved, so a
/// request is usually met in fewer sweeps than are planned here. `sweeps` is
/// the budget, `sweepTravel` the per-sweep ceiling that keeps the endpoints
/// safe, and `truncated` still says the request is beyond what a safe gesture
/// can cover at unit gain.
struct ScrollGesture: Equatable {

    /// How many press-drag sweeps the travel is spread across.
    let sweeps: Int
    /// The travel of a single sweep, in points.
    let sweepTravel: CGFloat
    /// True when `maxSweeps` truncated the request — the caller reports it
    /// rather than quietly moving less than it was asked for.
    let truncated: Bool

    /// The fraction of the container one sweep may span. A fifth leaves each
    /// endpoint two fifths of the container's height clear of its edges: the
    /// measured safe margins were ~88 points below an iPad sheet's top edge
    /// (of a 650-point container) and ~288 points from a visionOS window's
    /// edges (of a 720-point one), and 0.2 clears both.
    static let sweepSpanFraction: CGFloat = 0.2
    /// A backstop against a huge `amount:` in a short container turning into
    /// a hundred gestures. Hit, the sweep count is honest about it.
    static let maxSweeps = 8

    /// Splits `requestedTravel` into sweeps that fit in `containerHeight`.
    static func plan(requestedTravel: CGFloat, containerHeight: CGFloat) -> ScrollGesture {
        let span = max(containerHeight * sweepSpanFraction, 1)
        let wanted = max(Int(ceil(requestedTravel / span)), 1)
        let sweeps = min(wanted, maxSweeps)
        // Even sweeps rather than n full ones and a remainder: a gesture is
        // cheap, and equal ones keep the reported travel easy to reason about.
        return ScrollGesture(
            sweeps: sweeps,
            sweepTravel: min(requestedTravel / CGFloat(sweeps), span),
            truncated: wanted > maxSweeps
        )
    }

    /// What the gesture actually travels, which is the request unless
    /// `maxSweeps` truncated it.
    var totalTravel: CGFloat { CGFloat(sweeps) * sweepTravel }

    /// One sweep's endpoints, as offsets from the container's vertical centre.
    ///
    /// `dir:down` means "show me what is below", so the finger travels UP: it
    /// presses at the positive (lower on screen) offset and releases at the
    /// negative one.
    func offsets(goingDown: Bool) -> (press: CGFloat, release: CGFloat) {
        Self.offsets(travel: sweepTravel, goingDown: goingDown)
    }

    /// The same endpoints for a sweep whose travel was sized by
    /// `ScrollFeedback` rather than taken from the plan (#1193). Never larger
    /// than `sweepTravel`, so the middle-fifth property still holds.
    static func offsets(travel: CGFloat, goingDown: Bool) -> (press: CGFloat, release: CGFloat) {
        let sign: CGFloat = goingDown ? 1 : -1
        return (sign * travel / 2, -sign * travel / 2)
    }
}

/// Whether a `scroll` gesture achieved anything, and whether another one is
/// worth making — the rule behind the swipe fallback (#1191).
///
/// A synthesized press-and-drag scrolls nothing at all on visionOS. Measured
/// there on 26.5 against both the message list and the Settings form, in
/// every shape the verb can produce: endpoints derived with `withOffset`,
/// endpoints given as plain normalized offsets inside the container, one
/// sweep of a fifth of the container, one sweep of nine tenths of it, and a
/// quarter-second press dragged at `.slow` with a hold at the end. All of
/// them left every row on the point, and all of them reported a plausible
/// travel — the silent failure #1188 was also about.
///
/// `XCUIElement.swipeUp()` does scroll there, so the verb keeps the
/// press-drag it has (which is precise, and which iPadOS honours) and falls
/// back to a swipe when it measures that nothing moved. Nothing here asks
/// what platform it is on: the fallback is chosen by what the gesture did,
/// which is also what makes it self-retiring if a future visionOS starts
/// honouring the drag.
///
/// A swipe's travel is not adjustable — `.slow`, `.default` and `.fast` all
/// moved the visionOS message list by exactly 435 points in a 393-point
/// container — so `amount:` can only be honoured by swiping more than once,
/// and the verb reports what it measured rather than what it planned.
enum ScrollProgress {

    /// Displacements below this are the tree settling, not a scroll.
    static let stillThreshold: CGFloat = 1

    /// Whether the anchor moved between two readings.
    ///
    /// `nil` means the element left the accessibility tree, which on this
    /// path is the strongest evidence of a scroll there is: it scrolled far
    /// enough to stop being rendered.
    static func moved(from before: CGFloat?, to after: CGFloat?) -> Bool {
        guard let before else { return false }
        guard let after else { return true }
        return abs(after - before) >= stillThreshold
    }

    /// Whether to swipe again: only while there is travel left to cover, the
    /// sweep budget is unspent, and the last swipe actually moved something.
    ///
    /// The last clause is what stops a list that has reached the end of its
    /// content from spending the whole budget rubber-banding.
    static func shouldSwipeAgain(
        travelled: CGFloat,
        requested: CGFloat,
        swipes: Int,
        lastStep: CGFloat
    ) -> Bool {
        guard swipes < ScrollGesture.maxSweeps else { return false }
        guard lastStep >= stillThreshold else { return false }
        return travelled < requested
    }
}

/// Sizes each press-drag sweep from what the earlier ones actually moved.
///
/// `ScrollGesture` plans the travel *the finger* covers. What the content
/// covers is a different number, because #1192 spends the request in several
/// sweeps and each one is a separate press-and-drag that contributes its own
/// momentum: measured on iPhone 26.5, one default `dir:down` from the top of
/// Settings dragged 437 points and moved the form about 2.3 times that,
/// scrolling past three sections a single pre-#1192 sweep of the same total
/// length left on screen (#1193). The verb still reported 437, so every
/// recorded recipe that steps by default-amount scrolls landed somewhere
/// else, and the failure surfaced as `no element for 'text:X'` on the *next*
/// command rather than as anything wrong-looking on the scroll.
///
/// The cure is to close the loop the swipe fallback already closes — its own
/// doc comment says the verb "reports what it measured rather than what it
/// planned", and that contract was only ever honoured on one of the two
/// paths. After each sweep the ratio of measured displacement to finger
/// travel is known, so the next sweep is sized for what is left at that
/// ratio, and the verb stops as soon as the request is covered.
enum ScrollFeedback {

    /// Travel below this is not worth a gesture: the remainder lands inside
    /// the settling noise, and a sweep of a few points is as likely to be
    /// read as a tap.
    static let minimumSweepTravel: CGFloat = 8

    /// Floor on the measured-per-dragged ratio. Without it a sweep that
    /// happened to move almost nothing — the last one before a list hits the
    /// end of its content — would ask the next one to travel a wild multiple
    /// of the container. The cap does the same job from above; this keeps the
    /// arithmetic sane in between.
    static let minimumGain: CGFloat = 0.25

    /// The finger travel for the next sweep, or nil when the request has been
    /// met (or what is left of it is too small to be worth a gesture).
    ///
    /// `cap` is the per-sweep ceiling `ScrollGesture` planned, which is what
    /// keeps both endpoints inside the middle fifth of the container — the
    /// property #1188 exists to hold, and nothing here may raise it.
    static func nextSweepTravel(
        requested: CGFloat,
        measured: CGFloat,
        dragged: CGFloat,
        cap: CGFloat
    ) -> CGFloat? {
        let remaining = requested - measured
        guard remaining >= minimumSweepTravel else { return nil }
        // The first sweep has nothing to learn from, so it takes the plan's
        // figure unchanged — the pre-#1193 geometry exactly.
        let gain = (dragged > 0 && measured > 0) ? measured / dragged : 1
        let wanted = remaining / max(gain, minimumGain)
        return min(max(wanted, minimumSweepTravel), cap)
    }
}
