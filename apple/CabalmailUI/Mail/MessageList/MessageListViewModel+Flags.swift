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

    /// The flag the one-press controls set and clear: the first enabled
    /// entry of Settings > Flags, or nil when the palette has none (see
    /// `FlagToggle`). Read on every row build, like `disposeAction`, so a
    /// reorder or a rename takes effect at once.
    var defaultFlag: FlagToggle? { FlagToggle.defaultFlag(in: flagPalette) }

    /// Flip the default flag: the swipe action and the row menu's first
    /// item. Nothing to do while there is no default flag; the controls
    /// that call this are hidden then.
    func toggleDefaultFlag(_ envelope: Envelope) async {
        guard let flag = defaultFlag?.flag else { return }
        await toggle(flag, on: envelope)
    }

    /// Flip one palette flag, the built-in one or a custom slot. Rides the
    /// same optimistic primitive as the read toggle; a custom slot moves
    /// no count (the `default` arm in `CountMoves.move`).
    func toggle(_ flag: Flag, on envelope: Envelope) async {
        await setFlag(flag, add: !envelope.flags.contains(flag), envelope: envelope)
    }
}
