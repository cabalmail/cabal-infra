import SwiftUI

/// A whole-row tap action for a `List` row that also carries
/// `.swipeActions`, without wrapping the row in a `Button`.
///
/// On a touch Mac (macOS 27), a `Button` filling a `List` row keeps a
/// finger's horizontal swipe from reaching the row's swipe actions: the
/// trackpad's two-finger swipe still reveals them and one finger still
/// scrolls the list, but a finger's swipe reveals nothing. A tap gesture on
/// the same row leaves the swipe to the list. This was found on the address
/// list; a device build with the row's `Button` replaced by a tap gesture
/// swiped under a finger, with its `.draggable` kept or not.
///
/// For assistive technology the row stays what the `Button` made it: one
/// element with the button trait, read by `label`, whose default action
/// (VoiceOver's activate, an `AXPress`) runs `action`. `RowTapActionTests`
/// drives a real click and an `AXPress` through a row in a `List`.
struct RowTapAction: ViewModifier {
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    /// Makes the whole row run `action` on a tap or click, read as a button
    /// called `label`, without a `Button` that would take a finger's swipe
    /// from the row's swipe actions on a touch Mac. See `RowTapAction`.
    func rowTapAction(_ label: String, perform action: @escaping () -> Void) -> some View {
        modifier(RowTapAction(label: label, action: action))
    }
}
