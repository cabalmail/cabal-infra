import Foundation

/// Where compose opens, and where its sheet sits. Pure rules, so they can be
/// tested for every answer on whichever platform the tests run; the caller
/// (`ComposeRequestRouter`) reads the window.
///
/// On iOS compose is a sheet over the window it was asked from, in every
/// layout: an iPhone, an iPad and an iPhone Duo open or closed alike (the
/// Duo spec, Decision 8 in docs/1.x/post-wave-3/duo-support.md), and a
/// window only on request, from the sheet. The Mac and visionOS never
/// present the sheet and open a compose window instead.
enum ComposeSurfacePolicy {
    /// Whether compose opens as its own window rather than the sheet.
    ///
    /// - Parameter alwaysWindows: `platformAlwaysWindows`, true on the Mac
    ///   and visionOS. Nothing on iOS opens a window by itself any more: an
    ///   iPad, or an open iPhone Duo, could open one, but a reply there now
    ///   stays over the message it answers.
    static func opensInWindow(alwaysWindows: Bool = platformAlwaysWindows) -> Bool {
        alwaysWindows
    }

    /// What a main window's compose surface does with a seed it is offered.
    enum Offer: Equatable {
        /// Opens a compose window on it.
        case window
        /// Presents it in the surface's sheet.
        case sheet
        /// Takes nothing now; the seed waits with `ComposeCoordinator`.
        case refuse
    }

    /// - Parameters:
    ///   - hasClient: whether a session is wired. Without one the surface
    ///     builds no composer: its window is signing out, and the view is
    ///     about to go, so a seed handed to it then would be lost.
    ///   - opensInWindow: `opensInWindow()`.
    ///   - sheetIsUp: whether the surface's sheet is showing a compose,
    ///     which a second seed must not replace.
    static func offer(hasClient: Bool, opensInWindow: Bool, sheetIsUp: Bool) -> Offer {
        guard hasClient else { return .refuse }
        if opensInWindow { return .window }
        return sheetIsUp ? .refuse : .sheet
    }

    /// Whether the compose sheet offers "Open in New Window", which moves its
    /// draft to a compose window of its own (`ComposeWindowMove`).
    ///
    /// Only at regular width in a scene that can open another window beside
    /// it: an iPad, or an open iPhone Duo. Not in Slide Over or a narrow
    /// window, where a second window would cover the first; not on a large
    /// iPhone held wide, which is regular in width but cannot open one; not
    /// on a closed Duo. And never where compose is a window already, the Mac
    /// and visionOS.
    static func offersNewWindow(
        supportsMultipleWindows: Bool,
        isRegularWidth: Bool,
        alwaysWindows: Bool = platformAlwaysWindows
    ) -> Bool {
        !alwaysWindows && supportsMultipleWindows && isRegularWidth
    }

    /// Whether the compose sheet sits on the window's trailing side (the
    /// spec's "replies on the trailing side in flat wide windows"), leaving
    /// the window's leading side in view, rather than where the system puts
    /// it.
    ///
    /// Only in a window wider than it is tall that is regular in both size
    /// classes: an iPad in landscape, an open iPhone Duo held wide, flat or
    /// in book pose. A tall window keeps the system's placement, centred on
    /// an iPad and the Duo's inner display; so does every compact one,
    /// where a sheet takes the width anyway (an iPhone, a closed Duo, a
    /// large iPhone held wide, whose height is compact).
    static func sheetSitsTrailing(windowIsWide: Bool, isRegularWidth: Bool, isRegularHeight: Bool) -> Bool {
        windowIsWide && isRegularWidth && isRegularHeight
    }

    /// The host platform's answer (`HostPlatform.alwaysWindows`), as a value
    /// so the rule above can be exercised for both answers on whichever
    /// platform the tests run.
    static let platformAlwaysWindows = HostPlatform.current.alwaysWindows
}
