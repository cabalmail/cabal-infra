import SwiftUI

/// A refresh affordance that swaps the clockwise-arrows glyph for an
/// indeterminate spinner while a list reloads, *without changing size*.
///
/// SwiftUI's default `ProgressView()` spinner is larger than an
/// `arrow.clockwise` glyph, so naively swapping one for the other grows the
/// enclosing button and shoves its neighbors around. The motivating case was
/// the message-list reload button displacing the adjacent New Message button
/// every time a refresh started. Controls that move without warning invite
/// mis-clicks, so the spinner must stay constrained to the glyph's footprint.
///
/// How it stays put: the glyph always occupies the layout slot (hidden via
/// `opacity` while loading) and the spinner rides in an `overlay`, which never
/// feeds back into the parent's measured size. `.controlSize(.small)` keeps the
/// spinner visually inside the glyph's bounds. The footprint is therefore
/// identical in both states.
///
/// Callers attach their own `.accessibilityLabel(...)` (toolbar icon buttons)
/// or supply visible text via a `Label` whose `icon` is this view (list rows),
/// matching the surrounding call-site style.
struct RefreshActivityIcon: View {
    let isLoading: Bool

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
    }
}
