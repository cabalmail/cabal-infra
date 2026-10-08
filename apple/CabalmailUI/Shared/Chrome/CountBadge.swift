import SwiftUI
import CabalmailKit

/// A sidebar row's count capsule: what `FolderCountBadge` says the user's
/// Folder counts preference shows, drawn the same on a mail folder and on
/// a feed. Draws nothing when the rule hides the badge, so a caught-up row
/// has no empty capsule.
///
/// The digits are monospaced so the capsule keeps its width as a count
/// ticks. The text is the row's own full-strength colour, as the feed rows
/// drew it, rather than `.secondary`: that weaker fill is the one #993 found
/// unreadable over visionOS passthrough for the filter pills' counts.
struct CountBadge: View {
    let display: FolderCountDisplay
    let unread: Int?
    let total: Int?

    var body: some View {
        if let text = FolderCountBadge.text(display: display, unread: unread, total: total) {
            Text(text)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
                .accessibilityLabel(
                    FolderCountBadge.accessibilityLabel(display: display, unread: unread, total: total) ?? text
                )
        }
    }
}
