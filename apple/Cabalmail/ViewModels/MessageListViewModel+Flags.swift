import Foundation
import CabalmailKit

// Per-row flag actions (the swipe / menu read/flag toggles). Thin wrappers over
// `setFlag`, pulled into a sibling extension so the primary view-model body
// stays under SwiftLint's type-body length cap.
extension MessageListViewModel {
    func markRead(_ envelope: Envelope) async {
        await setFlag(.seen, add: true, envelope: envelope)
    }

    /// Flip the `\Seen` flag -- drives the leading (left-to-right) swipe
    /// action. Mirrors the Mail.app convention that the same gesture toggles
    /// between read and unread rather than having two.
    func toggleSeen(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.seen)
        await setFlag(.seen, add: add, envelope: envelope)
    }

    func toggleFlag(_ envelope: Envelope) async {
        let add = !envelope.flags.contains(.flagged)
        await setFlag(.flagged, add: add, envelope: envelope)
    }
}
