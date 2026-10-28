import Foundation

/// One main window's compose sheet as its navigation sees it
/// (`SceneNavigator.composeLock`): whether the sheet is up, and the deep link
/// that came for the window meanwhile.
///
/// While the sheet is up nothing acts on the message behind it: the menus
/// dim (`SignedInRootView` publishes no `WindowCommands`), the hidden chord
/// buttons go (`WindowCommands.disposeChordHost(in:)`, the reader's
/// `readerChordHosts`), and a deep link waits for the sheet to close
/// (`SceneNavigator.open(_:)`), so a reply never ends up beside a different
/// message. `ComposeRequestRouter` sets `isUp` as its sheet comes and goes.
///
/// The waiting link is held here rather than parked with `DeepLinkRouter`:
/// a parked link is any window's to take, and this one is this window's
/// alone. The last link sent wins.
@Observable
@MainActor
final class ComposeLock {
    var isUp = false
    @ObservationIgnored private var waiting: DeepLink?

    /// Holds `link` for the sheet to close, if the sheet is up. False when
    /// it is not, and the caller opens the link now.
    func holds(_ link: DeepLink) -> Bool {
        guard isUp else { return false }
        waiting = link
        return true
    }

    /// The sheet has closed: the link that waited for it, if any.
    func release() -> DeepLink? {
        isUp = false
        defer { waiting = nil }
        return waiting
    }
}
