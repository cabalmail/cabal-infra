import SwiftUI

/// What a compose window's scene phase means once its composer has closed.
///
/// A closed compose window is only off screen. On iPhone Duo the system
/// keeps listing it in the window switcher and the "Views Open" pill, and
/// iOS refuses an app's request to destroy its scene session there ("not
/// supported for this device idiom"). Picked again, it came back as a live
/// composer holding the draft it had sent or discarded, Send included
/// (#2257). iPad keeps the scene connected too (#1084).
///
/// So a closed window that has left the screen composes nothing
/// (`ComposeSlotRegistry.mayCompose`), and one that comes back to the front
/// leaves again. A close can finish with the window already in the
/// background: Send, Save Draft and Discard wait on the server, and the user
/// may have moved on by then. That window has left the screen too.
///
/// And a closed window may never leave the screen. In Split View on a phone
/// the window it hands the screen to is already in the other half, so
/// nothing covers it, and the system won't destroy it; it kept showing its
/// composer, draft and all (#2271). A window still on screen `lingerLimit`
/// after its close is spent as well, and says its message is closed.
extension ComposeSlotRegistry.ClosedCompose {
    /// How long a closed window keeps drawing its composer while it is still
    /// on screen: long enough to animate away when another window covers it.
    static let lingerLimit: Duration = .seconds(1)

    /// Records the phase the window was in when its composer closed.
    mutating func closed(in phase: ScenePhase) {
        if phase == .background { isSpent = true }
    }

    /// The window was still on screen `lingerLimit` after its composer
    /// closed.
    mutating func lingered() {
        isSpent = true
    }

    /// Applies a change of the window's phase after its composer closed, and
    /// answers whether the window should leave the screen again: it has come
    /// back to the front from the switcher, before or after it reached the
    /// background.
    mutating func sceneMoved(from old: ScenePhase, to new: ScenePhase) -> Bool {
        if new == .background { isSpent = true }
        guard new == .active, old != .active else { return false }
        isSpent = true
        return true
    }
}
