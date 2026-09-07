import SwiftUI

/// The one warning orange the app draws, per colour scheme.
///
/// A pure rule rather than an inline colour at each site, the way
/// `FolderNameTint` and `FolderIconTint` are, so the ratios below can be
/// asserted directly.
///
/// Every warning surface shipped as a plain `.orange`. `systemOrange` is a
/// light colour in both appearances — the platforms resolve it to
/// `(255, 141, 40)` in the light one and `(255, 146, 48)` in the dark one —
/// so on a light row it measures **2.31:1**, under the 4.5:1 WCAG AA floor
/// for text and under even the 3:1 floor for non-text. Over a dark row it
/// measures 6.24:1 and was never the problem.
///
/// No single orange clears both. A light row is white on iOS and near-white
/// on macOS; the compose form's dark row is `(44, 44, 46)`. Those pull in
/// opposite directions: the shipped orange is 2.31:1 / 6.24:1, and the
/// darkened one below is 6.53:1 / 2.13:1. So the colour has to follow the
/// scheme — which is why this is a rule and not a constant, and why the fix
/// is not simply "pick a darker orange".
///
/// The app pins its own appearance (Settings ▸ Appearance ▸ Theme) rather
/// than following the system, so both branches are reachable on every
/// platform regardless of what the OS is set to.
///
/// Named for the job rather than for one site: #1453 fixed the compose
/// attachment-size warning alone, and #1456 measured the seven other
/// foreground `.orange` sites and found five more failures. The watch's two
/// draw on black (7.12:1 and 9.41:1) and keep the platform colour; they are
/// in a different target and do not compile this file.
enum WarningTint: Equatable {
    /// The platform's own `systemOrange`, which the dark appearance already
    /// resolves clear of the floor.
    case systemOrange
    /// `systemOrange` darkened by `darkeningFactor`, for the light
    /// appearance.
    case darkened

    static func tint(for colorScheme: ColorScheme) -> Self {
        colorScheme == .dark ? .systemOrange : .darkened
    }

    /// What the site actually draws in.
    var color: Color {
        switch self {
        case .systemOrange: Color.orange
        case .darkened: Self.darkenedOrange.color
        }
    }

    /// `systemOrange` as the light appearance resolves it, measured off the
    /// reported screenshots. Recorded because `darkenedOrange` is derived
    /// from it, so the derivation stays legible if the platform ever moves
    /// the colour.
    static let systemOrangeLight = Components(red: 255, green: 141, blue: 40)

    /// Alpha of the wash `AuthResultsLine` lays under a chip's label, in the
    /// chip's own colour.
    ///
    /// Load-bearing here rather than a bare literal at the call site,
    /// because it is what makes the chip the *worst* light surface this
    /// tint draws on: the label's background is derived from the label's own
    /// colour, so darkening the text lightens the thing it is measured
    /// against and part of the gain is given straight back. Every other site
    /// draws on a row the tint has no say in.
    static let chipWashOpacity = 0.12

    /// Fraction of `systemOrangeLight` the light-appearance colour keeps.
    ///
    /// Scaling every channel by the same factor holds the hue and
    /// saturation the platform picked and moves only the value, so a warning
    /// still reads as the same warning orange rather than as a new colour.
    ///
    /// Chosen against the worst light surface, not against white. On white
    /// 0.65 measures 5.04:1 and would do (that is what #1453 shipped), but
    /// on the chip's own wash it is 4.30:1 — under the floor — and 0.60 is
    /// 4.84:1 there, which the iPad Addresses inspector's dimming projects
    /// back under (#1456 measured that presentation taking the shipped
    /// orange from 2.31:1 to 2.12:1). 0.55 measures 6.53:1 on white and
    /// 5.47:1 on the wash, which leaves the dimmed surface headroom.
    static let darkeningFactor = 0.55

    /// The light appearance's colour: `(140, 78, 22)`.
    static let darkenedOrange = systemOrangeLight.scaled(by: darkeningFactor)

    /// An sRGB colour pinned by 8-bit component, so a test can compute its
    /// contrast without having to read one back out of a `Color`.
    struct Components: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        func scaled(by factor: Double) -> Self {
            Self(
                red: (red * factor).rounded(),
                green: (green * factor).rounded(),
                blue: (blue * factor).rounded()
            )
        }

        var color: Color {
            Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
        }
    }
}
