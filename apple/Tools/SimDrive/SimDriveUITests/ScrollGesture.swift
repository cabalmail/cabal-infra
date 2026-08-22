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
/// and the verb reports what it measured rather than what it planned. On
/// both paths that includes declining to report at all once the witness has
/// left the tree, which is where the measurement ends (#1216).
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

/// Whether the element a `scroll … until:<query>` is aiming at has arrived
/// on screen (#1208).
///
/// `exists` is not the question. An unrealized SwiftUI row does not exist,
/// but a row that has scrolled *out* often still does, reporting a frame in
/// content space that lies outside its container's clip bounds — so an
/// existence check both under- and over-reports. What a recipe means by "on
/// screen" is "the next command can address it", and the next command is
/// usually a tap, so the rule is geometric: the element has to be inside the
/// scrolling container, not merely known to it.
///
/// Full containment rather than any overlap, because a row half-drawn at the
/// fold is exactly the one whose tap lands on whatever floats over the edge —
/// measured on visionOS, where the bulk bar covers the bottom of the list
/// column and a checkbox the tree places there is behind it. An element
/// taller than its own container can never be fully contained, so for that
/// case the bar is the most it could ever show.
enum ScrollDestination {

    /// Slack for the sub-point arithmetic AX frames come back with.
    static let tolerance: CGFloat = 0.5

    static func isOnScreen(element: CGRect?, container: CGRect) -> Bool {
        guard let element, !element.isEmpty, !container.isEmpty else { return false }
        let overlap = element.intersection(container)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        let needed = min(element.height, container.height)
        return overlap.height >= needed - tolerance
    }
}

/// Splitting `scroll`'s `until:` clause off the rest of the command (#1208).
///
/// A pure function because the rule is fiddlier than it looks and the REPL is
/// an expensive place to discover that. `until:` takes everything after it
/// verbatim, so its query may contain spaces the way the anchor's already
/// may; the option parser everywhere else splits on spaces and could not tell
/// `text:All folders` from a stray token. The cost is that `until:` has to be
/// the last thing on the line, which the usage text says.
enum ScrollCommand {

    /// The command with the clause removed, and the clause's query.
    ///
    /// `nil` means there was no `until:` at all — distinct from an empty
    /// query, which is a caller error worth naming rather than a default.
    static func splitUntilClause(_ remainder: String) -> (head: String, until: String?) {
        guard let range = remainder.range(of: "until:") else { return (remainder, nil) }
        // Only as a whole token: a query of `text:until:x` is far-fetched, but
        // matching mid-word would silently mangle it.
        let precedingIsBoundary = range.lowerBound == remainder.startIndex
            || remainder[remainder.index(before: range.lowerBound)] == " "
        guard precedingIsBoundary else { return (remainder, nil) }
        let head = String(remainder[..<range.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let until = String(remainder[range.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return (head, until)
    }
}

/// What the swipe fallback can honestly say about how far the content moved
/// (#1216).
///
/// A swipe's step is fixed and `amount:` cannot buy any of it, so the only
/// measurement this path has is the witness's displacement between sweeps.
/// When the witness leaves the accessibility tree that measurement ends —
/// and the code printed the *request* in its place, unqualified, which is
/// silently wrong in the reassuring direction. It lands in the usual case
/// rather than an exceptional one: the natural thing to anchor on is the
/// thing you want scrolled away, and on visionOS this is the only path that
/// scrolls anything at all.
///
/// The press-drag path in the same verb already refuses to answer here
/// (#1193, PR #1204). This is that refusal, stated as data so it can be
/// tested away from a simulator.
enum SwipeWitness: Equatable {

    /// The witness answered before and after every sweep, so the total is a
    /// measurement.
    case tracked

    /// The witness left the tree partway. Sweeps before that one were
    /// measured; the sweep that lost it, and everything after, were not.
    case leftView

    /// The witness was not in the tree when the first sweep started, so
    /// nothing was measured at all.
    case neverSeen
}

/// The swipe fallback's tally, kept apart from the budget that stops it.
///
/// `travelled` was doing both jobs before #1216 — feeding
/// `ScrollProgress.shouldSwipeAgain` and feeding the answer — and the
/// vanished-witness branch wrote the request into it. That write never had a
/// stopping role (the branch breaks unconditionally); its only effect was on
/// what got printed.
struct SwipeFallbackResult: Equatable {

    /// Displacement actually observed, over the sweeps that could be
    /// measured. Never the request.
    var measured: CGFloat

    /// Sweeps performed, measurable or not.
    var swipes: Int

    /// Whether `measured` is the whole story.
    var witness: SwipeWitness

    /// The line the REPL prints.
    ///
    /// `query` is echoed rather than described because it is what the caller
    /// has to change to get a measurement: anchoring on something that stays
    /// is the fix, and naming the anchor is how the answer says so.
    func summary(query: String, goingDown: Bool) -> String {
        let direction = goingDown ? "down" : "up"
        let plural = swipes == 1 ? "" : "s"
        let path = "drag fallback — a press-drag moved nothing here"
        switch witness {
        case .tracked:
            return "scrolled \(query) \(direction) (\(Int(measured))pt in \(swipes) swipe\(plural), \(path))"
        case .leftView:
            let before = measured >= ScrollProgress.stillThreshold
                ? " — at least \(Int(measured))pt before it did"
                : ""
            return "scrolled \(query) \(direction) (\(swipes) swipe\(plural), \(path); "
                + "\(query) left the view, so the distance it moved is not measurable\(before) — "
                + "anchor on something that stays to get one)"
        case .neverSeen:
            return "scrolled \(query) \(direction) (\(swipes) swipe\(plural), \(path); "
                + "\(query) was not on screen to measure against, so the distance is not "
                + "measurable — anchor on something that stays to get one)"
        }
    }
}
