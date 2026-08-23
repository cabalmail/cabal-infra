import XCTest

/// Which simulator platform the runner is driving.
///
/// **Not a compile-time question.** The test bundle is built `platform: iOS`
/// (see `project.yml`) and runs on visionOS in compatibility mode, so
/// `#if os(visionOS)` is false in every build this harness produces. A guard
/// written that way compiles, passes its unit tests, and never fires — which
/// is exactly what happened on the first cut of #1238's fix: green suite,
/// dead runner on the very command the issue reports.
///
/// The host script knows, because it picks the `-destination` platform from
/// the udid's runtime (`platform_for_udid`), and it already maintains a
/// rendezvous file the runner reads for the same reason this matters —
/// visionOS drops `TEST_RUNNER_*` environment injection (#872). So the
/// platform travels the same way.
enum DriveHost: Equatable {

    case visionOS

    /// Every host where an application-anchored coordinate is a working
    /// gesture: iOS, iPadOS, tvOS.
    case coordinateCapable

    /// Maps whatever the host wrote — `"visionOS Simulator"`, `"iOS
    /// Simulator"`, or nothing at all — onto the capability that matters.
    ///
    /// An absent or unrecognised value resolves to `.coordinateCapable`: a
    /// stale rendezvous file or a hand-started runner must not lose `tap xy:`
    /// on the platforms where it works, which is the control this fix has to
    /// leave intact. The cost of that default is the pre-fix behaviour on
    /// visionOS, never a regression elsewhere.
    static func resolve(hostPlatform: String?) -> DriveHost {
        guard let hostPlatform else { return .coordinateCapable }
        let normalized = hostPlatform.lowercased()
        if normalized.contains("visionos") || normalized.contains("xros") {
            return .visionOS
        }
        return .coordinateCapable
    }
}

/// Whether an `xy:` coordinate can be delivered on a given host (#1238).
///
/// Every coordinate the driver builds is anchored on the application element,
/// and on visionOS that event cannot be synthesized: XCTest raises `Failed to
/// synthesize event: Received invalid scene ID (nil) from Accessibility`. That
/// is an XCTest *failure*, not a Swift error, so it unwinds `testDriveLoop`
/// and every command queued afterwards answers `runner is gone` — the same
/// class of fatal call site `key` closed in #1222 and #1230, and it costs a
/// runner restart rather than an error line. The charter had recorded it since
/// #1157 as a hazard of tapping the compose rich-text pane; it is not
/// pane-specific, and two arbitrary coordinates reproduced it in #1238.
///
/// Refusing rather than re-anchoring is a measured choice. An element-anchored
/// coordinate is accepted by visionOS — `swiperow` and `scroll` have always
/// ridden one — so re-homing the anchor is the obvious cure, and it does not
/// work: anchored on the innermost window containing the point (`{{0, 0},
/// {1280, 720}}`, the main window, correct coordinate space), a tap on the
/// centre of `filter.pill.unread` returned `ok` and moved nothing, while
/// `tap id:filter.pill.unread` at the same point in the same session flipped
/// the list from 12 rows to 2 and back. A window anchor buys a survivable
/// no-op, which is worse than an error: a recipe that reports success and
/// changes nothing reads as a defect in the app.
///
/// So on visionOS `xy:` is refused up front, and the message names what does
/// work there. Both coordinate call sites — `tap xy:` and `drag` — go through
/// `coordinate(from:)`, so the rule lives there once rather than being copied
/// per verb (#1118).
enum CoordinateAnchor {

    /// The reason `xy:` cannot be served on this host, or `nil` if it can.
    static func refusal(on host: DriveHost) -> String? {
        guard host == .visionOS else { return nil }
        return "xy: coordinates are not deliverable on visionOS — synthesizing one "
            + "raises 'invalid scene ID' and kills the runner, and anchoring it in a "
            + "window lands nothing (#1238). Address the element instead: id:, text:, "
            + "sysid: or systext:, and use scroll/swiperow for gestures."
    }
}
