#if os(iOS)
import SwiftUI
import UIKit
import CabalmailKit

// Hardware-keyboard modifier-click selection for iPad / iPhone-with-keyboard.
//
// SwiftUI's native multi-select `List` translates shift / command clicks into
// selection changes on macOS (AppKit), but NOT on iOS - and the declarative
// hooks that would let us read modifier state (`Gesture.modifiers(_:)`,
// `onModifierKeysChanged`) are both `@available(iOS, unavailable)`. So on iOS
// we bridge a UIKit tap recognizer to read `modifierFlags` at click time. The
// recognizer fires only for taps carrying shift / command / control; every
// other tap is left to the List, so a plain tap still opens the message and a
// long-press still starts a drag.

/// What a modifier-held click should do to the selection.
enum ModifierClickKind {
    case toggle  // command / control: flip this row's membership
    case range   // shift: select the inclusive range from the anchor
}

struct ModifierClickGesture: UIGestureRecognizerRepresentable {
    let action: (ModifierClickKind) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UITapGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        let flags = recognizer.modifierFlags
        // Shift wins when both are held, matching the Finder / Mail convention
        // (shift extends, command toggles).
        if flags.contains(.shift) {
            action(.range)
        } else if flags.contains(.command) || flags.contains(.control) {
            action(.toggle)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        // Receive only modifier-held taps; a plain tap returns false here so it
        // falls through to the List's own selection / navigation.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive event: UIEvent
        ) -> Bool {
            !event.modifierFlags.isDisjoint(with: [.shift, .command, .control])
        }
    }
}

extension MessageListView {
    /// Apply a shift-click range selection over `ordered` (the visible rows in
    /// display order), from the current anchor to `target`, inclusive. Falls
    /// back to selecting just `target` if the anchor can't be located.
    func applyRangeSelection(to target: Envelope, model: MessageListViewModel, ordered: [Envelope]) {
        let anchorUID = model.selectionAnchor ?? model.selectedUIDs.first
        guard let anchorUID,
              let anchorIndex = ordered.firstIndex(where: { $0.uid == anchorUID }),
              let targetIndex = ordered.firstIndex(where: { $0.uid == target.uid }) else {
            model.selectedUIDs = [target.uid]
            model.selectionAnchor = target.uid
            return
        }
        let lower = min(anchorIndex, targetIndex)
        let upper = max(anchorIndex, targetIndex)
        model.selectedUIDs = Set(ordered[lower...upper].map(\.uid))
        // Keep the original anchor so a subsequent shift-click re-pivots from it.
    }

    /// Apply a command/control-click: flip the row's membership and make it the
    /// new anchor for any following shift-click.
    func applyToggleSelection(_ envelope: Envelope, model: MessageListViewModel) {
        model.toggleSelection(envelope)
        model.selectionAnchor = envelope.uid
    }
}
#endif
