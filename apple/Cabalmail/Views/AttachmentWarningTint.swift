import SwiftUI

/// How the compose attachment-size warning is coloured, per colour scheme.
///
/// A pure rule rather than an inline colour in `ComposeView+Subviews`, the
/// way `FolderNameTint` and `FolderIconTint` are, so the ratios below can be
/// asserted directly.
///
/// The row shipped as `.foregroundStyle(.orange)`. `systemOrange` is a light
/// colour in both appearances — the platforms resolve it to
/// `(255, 141, 40)` in the light one and `(255, 146, 48)` in the dark one —
/// so over the compose form's light row it measured **2.31:1**, under the
/// 4.5:1 WCAG AA floor for text and under even the 3:1 floor for non-text
/// (#1453, the same value on an iPhone 17 and an iPad Pro 11" at iOS 26.5).
/// Over the dark row it measures 6.24:1 and was never the problem.
///
/// No single orange clears both. The form draws this row on white in the
/// light appearance and on `(44, 44, 46)` in the dark one, and those pull in
/// opposite directions: the shipped orange is 2.31:1 / 6.24:1, and the
/// darkened one below is 5.04:1 / 2.77:1. So the colour has to follow the
/// scheme — which is why this is a rule and not a constant, and why the fix
/// is not simply "pick a darker orange".
///
/// The app pins its own appearance (Settings ▸ Appearance ▸ Theme) rather
/// than following the system, so both branches are reachable on every
/// platform regardless of what the OS is set to.
enum AttachmentWarningTint: Equatable {
    /// The platform's own `systemOrange`, which the dark appearance already
    /// resolves clear of the floor.
    case systemOrange
    /// `systemOrange` darkened by `darkeningFactor`, for the light
    /// appearance.
    case darkened

    static func tint(for colorScheme: ColorScheme) -> Self {
        colorScheme == .dark ? .systemOrange : .darkened
    }

    /// What the row actually draws in.
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

    /// Fraction of `systemOrangeLight` the light-appearance colour keeps.
    ///
    /// Scaling every channel by the same factor holds the hue and
    /// saturation the platform picked and moves only the value, so the row
    /// still reads as the same warning orange rather than as a new colour.
    /// 0.65 clears the AA floor with room to spare (5.04:1 on white) where
    /// 0.70 lands at 4.45:1, i.e. just under it — the margin is deliberate,
    /// because the form's light row is white on iOS and merely near-white
    /// on macOS.
    static let darkeningFactor = 0.65

    /// The light appearance's colour: `(166, 92, 26)`.
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
