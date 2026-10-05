import SwiftUI

/// Whether the From pop-up's label has to draw its own disclosure chevron.
///
/// A pure rule rather than an inline `#if` so it can be tested directly —
/// `FromPicker`'s body isn't reachable from a unit test, this is.
///
/// A `Menu` with a custom label draws exactly the label it is given on
/// iOS/iPadOS/visionOS, so the chevron is ours to supply or the control looks
/// like static text. AppKit's bordered menu adds its own at the trailing edge,
/// so supplying one there put **two** chevrons side by side inside the same
/// capsule — a light `.caption` one, then the system's (#1167). Same source
/// file, two platforms, one of them wrong: the platform is the whole variable.
enum FromPickerChevronPolicy {
    static func labelDrawsChevron(on platform: HostPlatform) -> Bool {
        // macOS is the only one whose menu style supplies its own.
        platform != .macOS
    }
}
