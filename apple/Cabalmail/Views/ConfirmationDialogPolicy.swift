import SwiftUI

/// Whether a `confirmationDialog`'s back-out button may carry
/// `ButtonRole.cancel`.
///
/// A pure rule rather than an inline `#if` at each call site so it can be
/// tested directly, and so there is one place to change if a future OS
/// draws these dialogs differently — nine dialogs answering the same
/// question independently is how eight of them stayed wrong after the ninth
/// was fixed (#838/#841 fixed compose; #1201 found the rest).
///
/// The role is load-bearing. On iPhone (and visionOS) a `confirmationDialog`
/// can render as an anchored popover, and SwiftUI *drops* the cancel-role
/// button there, running its action on an outside tap instead. In a dialog
/// whose other button is destructive that leaves the destructive action as
/// the only labelled control on screen, under a message saying the thing
/// can't be undone — the way out is real, but unlabelled and undiscoverable.
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
