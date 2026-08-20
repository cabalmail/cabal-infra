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
        let sign: CGFloat = goingDown ? 1 : -1
        return (sign * sweepTravel / 2, -sign * sweepTravel / 2)
    }
}
