import SwiftUI

/// The three outcomes of tapping Cancel in the composer, in the order the
/// confirmation dialog offers them.
///
/// Modelled as a type rather than three inline `Button`s so the set — and,
/// more importantly, which member carries the `.cancel` role — is unit
/// testable. That role is load-bearing: SwiftUI drops the cancel-role button
/// when a `confirmationDialog` renders as a popover (which is what iPhone
/// does here) and runs its action on an outside tap instead. "Save Draft"
/// used to hold the role, so the popover showed only the destructive button
/// and an accidental outside tap silently closed the composer.
enum ComposeCancelChoice: CaseIterable {
    case discard
    case saveDraft
    /// Deliberately a no-op: dismissing the dialog leaves the composer up,
    /// which is also what an outside tap now does.
    case keepEditing

    var title: String {
        switch self {
        case .discard:     return "Discard Draft"
        case .saveDraft:   return "Save Draft"
        case .keepEditing: return "Keep Editing"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .discard:   return .destructive
        case .saveDraft: return nil
        case .keepEditing:
            // iOS/visionOS render this dialog as a popover, where SwiftUI
            // suppresses cancel-role buttons and treats an outside tap as
            // the cancel — so a cancel-roled "Keep Editing" would be
            // invisible, exactly the hole this fix is closing. Leaving it
            // roleless keeps it on screen; the outside tap still resolves
            // to the system's implicit cancel, which is the same no-op.
            // macOS shows every button in an alert and maps Escape to the
            // cancel-roled one, so there the role is worth having.
            #if os(macOS)
            return .cancel
            #else
            return nil
            #endif
        }
    }
}
