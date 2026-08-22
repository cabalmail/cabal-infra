import SwiftUI

/// Whether a `confirmationDialog`'s back-out button may carry
/// `ButtonRole.cancel`.
///
/// A pure rule rather than an inline `#if` at each call site so it can be
/// tested directly, and so there is one place to change if a future OS
/// draws these dialogs differently — eleven dialogs answering the same
/// question independently is how ten of them stayed wrong after the first
/// was fixed (#838/#841 fixed compose; #1201 found the other eight;
/// #1207 the watch's two).
///
/// The role is load-bearing: SwiftUI *drops* a cancel-role button outright
/// on every platform but macOS, whatever the dialog is presented as.
/// Measured on all three — iPhone renders an anchored popover and runs the
/// button's action on an outside tap instead (#1201), while visionOS and
/// watchOS render a sheet and drop it there too (#1203, #1207). In a dialog
/// whose other button is destructive that leaves the destructive action as
/// the only labelled control on screen, under a message saying the thing
/// can't be undone. The presentation style is not the variable it first
/// looked like; the role is.
///
/// macOS presents the same dialogs as alerts, which draw every button and
/// map Escape onto the cancel-roled one, so there the role is worth having.
enum ConfirmationDialogPolicy {

    /// The role for the button that backs out of a confirmation dialog
    /// without performing its action.
    static func backOutRole(on platform: HostPlatform) -> ButtonRole? {
        platform == .macOS ? .cancel : nil
    }

    /// `backOutRole(on:)` for the platform this build is compiled for.
    static var backOutRole: ButtonRole? { backOutRole(on: .current) }
}
