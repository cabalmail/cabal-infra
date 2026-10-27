import CoreGraphics
import Foundation

/// One layout pass's reading of the window's fold: the active division
/// region, if there is one, in window coordinates, and the window's size.
/// `FoldGeometry` takes it from the root view's geometry on iOS 27.1; every
/// other host only ever reports no region.
struct FoldSample: Equatable, Sendable {
    var region: CGRect?
    var windowSize: CGSize
    /// The window's division region whether or not it is active, in window
    /// coordinates: where the crease is even while the device lies flat.
    /// Measured on the Duo simulator (iOS 27.1, 2026-10-27): flat, the
    /// inner display reports (455.5, 0, 40, 669) inactive, the same band
    /// book pose reports active; laptop and open portrait report
    /// (0, 455.5, 669, 40); the closed display reports none. `FoldHold`
    /// never reads it: an inactive region is not a fold.
    var division: CGRect?
}

/// The hinge, as far as the fold hold cares: its status and its angle in
/// degrees (180 is flat). `FoldGeometry` maps the SDK's `DeviceHinge` onto
/// it, so the hold can be tested on a host that has no hinge.
struct HingeReading: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case closed, partiallyOpen, fullyOpen
    }

    var status: Status
    var angle: Double
}

/// The two-pass rule: a reading counts only once two layout passes in a row
/// agree on it.
///
/// The first frame after a change can be stale. On the Studio's Duo
/// simulator a cold launch saw the fold region arrive about 60 ms after the
/// first layout pass, the bar edge read as unknown for a moment at every
/// switch between displays, and one frame after a close still carried the
/// inner display's fold. Anything placed from a single pass can therefore
/// jump to a wrong place and back. The caller feeds every pass it sees, plus
/// one confirming pass a moment after the last (a geometry callback only
/// fires on a change, so two real passes never agree on their own); a value
/// a newer pass replaced in the meantime never settles.
struct FoldSettler<Value: Equatable> {
    /// The value both of the last two agreeing passes read; nil until the
    /// first pair.
    private(set) var settled: Value?
    private var previous: Value?

    /// Takes one pass's reading. Returns it when it has just settled: this
    /// pass and the one before read it, and it is not what had settled
    /// already.
    mutating func pass(_ value: Value) -> Value? {
        defer { previous = value }
        guard previous == value, settled != value else { return nil }
        settled = value
        return value
    }
}

/// The hinge hold: the fold state a window is in, from its settled fold
/// samples and its hinge, holding a fold steady while the hinge moves.
///
/// Measured on the Studio's Duo simulator (Oct 7 spec): the division region
/// turns active 0.05 to 0.4 s after the hinge comes to rest, at no set
/// angle, and drops out whenever the hinge moves at all. A layout that
/// followed the region alone would unpin the list and move every toast on
/// each nudge of the hinge, then put them back. So a fold, once entered,
/// holds while the angle changes, and a fold whose region has dropped out
/// ends on a fully open hinge, after `grace` at rest, or when the window
/// changes size (a rotation, a close, a Split View change: the crease it
/// held is in the wrong place there). Losing the hinge altogether (a nil
/// reading, which Apple says to treat as "hinge unavailable") ends a held
/// fold too, since nothing can say it is still moving.
///
/// That is the only use the spec makes of hinge data, a deliberate
/// exception to Apple's advice to keep it for effects, and the region always
/// wins over it. Hinge data never *enters* a fold: the simulator read
/// "partially open" from about 11 degrees while the app stayed on the outer
/// display until about 55, so only an active region does. Nor does it end a
/// fold whose region is still there: a fully open hinge with an active
/// region ends the fold the moment the region drops, without the grace. A
/// closed status is treated as motion, not as an end: closing, the
/// simulator read "closed" from about 62 degrees, and where the window
/// leaves the inner display is unmeasured, so the size change ends it.
struct FoldHold {
    /// How long a fold outlives its region once the hinge is at rest: a
    /// starting value from the spec, for the Studio to tune at 110, 130, 170
    /// and 180 degrees on the hinge slider.
    static let defaultGrace: TimeInterval = 0.6

    var grace: TimeInterval
    private(set) var state: FoldState = .none

    /// The window size the fold was last seen at.
    private var windowSize: CGSize?
    /// When the region last dropped out while a fold held; nil while it is
    /// present, or when nothing is folded.
    private var regionLostAt: TimeInterval?
    /// When the hinge last moved.
    private var hingeMovedAt: TimeInterval?
    private var hingeAngle: Double?
    /// The last hinge reading was fully open.
    private var hingeIsFullyOpen = false

    init(grace: TimeInterval = Self.defaultGrace) {
        self.grace = grace
    }

    /// When `tick(at:)` would end the fold if nothing else happens first;
    /// nil when no fold is waiting to end.
    var deadline: TimeInterval? {
        guard state.isFolded, let lost = regionLostAt else { return nil }
        return max(lost, hingeMovedAt ?? lost) + grace
    }

    /// A settled fold sample (`FoldSettler`).
    mutating func observe(_ sample: FoldSample, at now: TimeInterval) {
        if let region = sample.region {
            state = FoldState(region: region)
            windowSize = sample.windowSize
            regionLostAt = nil
            return
        }
        guard state.isFolded else {
            windowSize = sample.windowSize
            return
        }
        if let held = windowSize, !Self.sameSize(held, sample.windowSize) {
            end()
            windowSize = sample.windowSize
            return
        }
        if hingeIsFullyOpen {
            end()
            return
        }
        if regionLostAt == nil {
            regionLostAt = now
        }
    }

    /// The hinge changed. Nil is no hinge, which Apple says to treat as
    /// "hinge unavailable" and reset what was derived from it: the hold,
    /// never a fold the region still backs.
    mutating func hingeChanged(_ reading: HingeReading?, at now: TimeInterval) {
        guard let reading else {
            if regionLostAt != nil { end() }
            forgetHinge()
            return
        }
        if let angle = hingeAngle, angle != reading.angle {
            hingeMovedAt = now
        }
        hingeAngle = reading.angle
        hingeIsFullyOpen = reading.status == .fullyOpen
        if hingeIsFullyOpen, regionLostAt != nil {
            end()
        }
    }

    /// Time passed: ends a held fold whose grace has run out.
    mutating func tick(at now: TimeInterval) {
        guard let deadline, now >= deadline else { return }
        end()
    }

    /// The hinge is read only while a fold holds (`FoldGeometry`), so what
    /// it said before goes with the fold: a stale angle would count as
    /// motion on the next fold's first reading.
    private mutating func end() {
        state = .none
        regionLostAt = nil
        forgetHinge()
    }

    private mutating func forgetHinge() {
        hingeAngle = nil
        hingeMovedAt = nil
        hingeIsFullyOpen = false
    }

    /// Within half a point: a size that differs by rounding is the same
    /// window.
    static func sameSize(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}

/// The division `foldGeometry()` publishes as `\.foldDivision`: the latest
/// settled one, kept through a settled reading that loses it while the
/// window keeps its size, and dropped by a reading at another size.
///
/// The hold is for the hinge. The active region drops out whenever the hinge
/// moves; whether the inactive one does too is unmeasured, and if it did, a
/// list sitting at the crease would jump to its default width and back on
/// the way into book pose. A different window size is a close, an open or a
/// rotation, after which the old crease is somewhere else, or nowhere.
struct DivisionHold: Equatable, Sendable {
    private(set) var division: CGRect?
    private var windowSize: CGSize?

    mutating func observe(_ sample: FoldSample) {
        if let new = sample.division {
            division = new
            windowSize = sample.windowSize
            return
        }
        if let held = windowSize, FoldHold.sameSize(held, sample.windowSize) { return }
        division = nil
        windowSize = nil
    }
}
