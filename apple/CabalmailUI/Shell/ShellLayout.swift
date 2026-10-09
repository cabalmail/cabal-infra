import SwiftUI

/// The layout shell a main window draws, decided once per window and
/// published to everything beneath it as `\.shellLayout`.
///
/// It is the one answer to "which layout is this?". A view that needs it
/// reads this value rather than a size class or an `#if os`: the size class
/// a view sees is its column's, not the window's (an iPad's list column
/// reports compact inside a regular-width split), and an `#if` can't tell the
/// iPad split from the iPhone tabs at all. A size class stays the right read
/// only where the question really is the column's own width
/// (`ReaderToolbarLayout`).
///
/// `SignedInRootView` resolves it from the window's traits and switches on
/// it; everything outside a main window's root gets `standalone`.
enum ShellLayout: Equatable {
    /// macOS: the three-column window with a tiled sidebar and the Settings
    /// scene.
    case desktop
    /// iPad, and iPhone Duo's inner display: the split with the floating
    /// folder panel and the Settings sheet.
    case split
    /// iPhone, iPhone Duo's outer display, and an iPad window narrowed to
    /// compact: one bottom tab per section.
    case tabs
    /// visionOS: the tab list as a leading ornament.
    case ornament

    /// The layout a window with these traits draws.
    ///
    /// Each platform has one shell, except iOS, where the window's size
    /// classes and measured width pick between the split and the tabs by
    /// `SectionLayoutPolicy` — whose doc carries why both size classes count
    /// and why the idiom doesn't. A pure function of its arguments, so every
    /// platform's answer is testable on the Mac host.
    ///
    /// - Parameters:
    ///   - platform: the platform being drawn on, `HostPlatform.current` in
    ///     the app.
    ///   - isCompactWidth: `horizontalSizeClass == .compact` (iOS only).
    ///   - isCompactHeight: `verticalSizeClass == .compact` (iOS only).
    ///   - measuredWidth: the window width last laid out at, nil before the
    ///     first layout (iOS only; see `SectionLayoutPolicy.regularWidthFloor`).
    static func resolve(
        on platform: HostPlatform,
        isCompactWidth: Bool,
        isCompactHeight: Bool,
        measuredWidth: CGFloat?
    ) -> ShellLayout {
        switch platform {
        case .macOS:
            return .desktop
        case .visionOS:
            return .ornament
        case .iOS:
            switch SectionLayoutPolicy.layout(
                isCompactWidth: isCompactWidth,
                isCompactHeight: isCompactHeight,
                measuredWidth: measuredWidth
            ) {
            case .compactTabs: return .tabs
            case .regularSplit: return .split
            }
        case .watchOS:
            // No watch target builds a shell (the watch app compiles
            // `HostPlatform` alone). A single stack is closest to the tabs.
            return .tabs
        }
    }

    /// What a view outside a main window's root reads — a compose window, the
    /// macOS Settings scene, a preview: the platform's own shell, and on iOS
    /// the tabs, which ask the least of a view (no wide-only chrome).
    static let standalone = resolve(
        on: .current, isCompactWidth: true, isCompactHeight: false, measuredWidth: nil
    )

    /// Whether the window is a split whose sidebar, list and reader share the
    /// screen: the desktop and the split. The navigator's `layoutIsWide`.
    /// visionOS's ornament is not one — its Mail tab is a list and a reader,
    /// with folders in a tab of their own.
    var isWideSplit: Bool {
        switch self {
        case .desktop, .split: return true
        case .tabs, .ornament: return false
        }
    }
}

extension EnvironmentValues {
    /// This window's layout shell (`ShellLayout`), published by
    /// `SignedInRootView`.
    @Entry var shellLayout: ShellLayout = .standalone
}
