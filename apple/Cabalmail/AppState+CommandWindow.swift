import Foundation

// MARK: - Command window targeting
//
// Which main window a command tick is for. The `request…` methods record
// the target in `commandWindow` as they bump a tick; the observers, through
// `onWindowCommand` (`MainWindowCommandScope.swift`), ask `commandReaches`
// before acting. A nil target reaches every window: that is what a
// data-change refresh wants (Empty Trash, a push action), and it keeps any
// caller that names no window working as it did before targeting existed.
@MainActor
extension AppState {
    /// Records `window` as the main window most recently in front.
    func noteActiveMainWindow(_ window: UUID) {
        lastActiveMainWindow = window
    }

    /// Forgets a main window that closed, so a command issued from a
    /// compose window cannot be aimed at a window no longer there.
    func forgetMainWindow(_ window: UUID) {
        if lastActiveMainWindow == window { lastActiveMainWindow = nil }
    }

    /// The window a menu command is for: the focused main window, or the
    /// one last in front when the key window is a compose or Settings
    /// window.
    func menuCommandTarget(focused: UUID?) -> UUID? {
        focused ?? lastActiveMainWindow
    }

    /// Whether the latest command tick is for the window `window`. A view
    /// outside any main window (nil) answers every tick, as before.
    func commandReaches(_ window: UUID?) -> Bool {
        guard let target = commandWindow, let window else { return true }
        return target == window
    }
}
