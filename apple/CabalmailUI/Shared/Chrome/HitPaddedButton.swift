import SwiftUI

/// A button that takes taps `hitPadding` beyond its label while its parent
/// lays it out at the label's own size, so the target grows and nothing
/// around it moves.
///
/// For a small glyph button in a tight row — a toast's close button, a
/// banner's refresh — where the room a finger needs is padding the row
/// already has, not spacing that could be handed to the button outright
/// (`RichTextToolbar.hitPadding` does that instead).
///
/// The padding has to be inside the button's own frame: on macOS a
/// `contentShape` larger than the view (`Rectangle().inset(by: -8)`) takes
/// no clicks beyond the frame. So the label is padded and given a
/// rectangular shape, which grows the button's frame, and the button is then
/// handed the padding back as negative padding, which keeps the parent's
/// layout where it was. Choose insets that stay inside the surrounding
/// padding and short of any neighbouring control, since the hit area now
/// reaches over them. `HitPaddedButtonTests` drives real clicks through it.
struct HitPaddedButton<Label: View>: View {
    let hitPadding: EdgeInsets
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    init(hitPadding: EdgeInsets, action: @escaping () -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.hitPadding = hitPadding
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            label()
                .padding(hitPadding)
                .contentShape(Rectangle())
        }
        .padding(EdgeInsets(
            top: -hitPadding.top, leading: -hitPadding.leading,
            bottom: -hitPadding.bottom, trailing: -hitPadding.trailing
        ))
    }
}
