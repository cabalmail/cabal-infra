import SwiftUI
import CabalmailKit

/// The unread mark that leads a mail row and a feed row: one dot, drawn
/// once so the two lists cannot drift apart.
///
/// The slot is always there. A read item draws it clear, so marking an
/// item read never shifts the rest of the row.
///
/// Painted in the brand forest green rather than the platform blue. The
/// asset-catalog color is pinned explicitly rather than taken from
/// `Color.accentColor`, which macOS repaints with the user's system accent
/// whenever that isn't "multicolor" (same reasoning as
/// `SidebarTreeRowLabel.iconStyle`).
struct UnreadDot: View {
    let isUnread: Bool

    var body: some View {
        Circle()
            .fill(isUnread ? ColorTokens.accentForestFg : Color.clear)
            .frame(width: 8, height: 8)
            // Sits on the first line of text in a top-aligned row.
            .padding(.top, 6)
            // The rows say "Unread" in words where they describe themselves.
            .accessibilityHidden(true)
    }
}
