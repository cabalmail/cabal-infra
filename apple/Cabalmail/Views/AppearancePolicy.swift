import SwiftUI
import CabalmailKit

/// Maps the Theme preference onto the appearance a scene draws in.
///
/// The rule itself is one line, and that is exactly why it kept getting
/// written out again: `CabalmailApp` and `CabalmailMacApp` each carried a
/// private copy, so the third scene — the standalone compose window, which
/// both targets install — simply never asked the question and fell back to
/// whatever appearance the OS was in (#1460). A scene is a separate
/// appearance root: `preferredColorScheme` does not cross from one to
/// another, so every scene the app installs has to pin the theme itself.
///
/// Lifted here as a pure function so the mapping has one home and one test,
/// and exposed through `View.themedAppearance(_:)` so a scene root asks for
/// it by name — `SceneAppearanceSourceScanTests` is what keeps a fourth copy
/// from appearing.
enum AppearancePolicy {

    /// `nil` means "follow the system appearance" — i.e. the `.system`
    /// preference lets the OS switch light/dark with its own controls.
    static func colorScheme(for theme: AppTheme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

extension View {
    /// Pins this scene root to the app's Theme preference.
    ///
    /// Applied to the *content* of every scene rather than once at the app
    /// level because SwiftUI has no app-level appearance: each `WindowGroup`
    /// / `Settings` scene resolves its own.
    func themedAppearance(_ theme: AppTheme) -> some View {
        preferredColorScheme(AppearancePolicy.colorScheme(for: theme))
    }
}
