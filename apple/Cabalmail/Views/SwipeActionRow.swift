import SwiftUI

// Swipe actions for the virtualized message list. `.swipeActions` used to
// be `List`-only, so after the ScrollView+LazyVStack rework
// (`project_apple_list_virtualization`) each row embedded a single-row
// `List` purely to borrow the native gesture -- the only way to keep the
// macOS two-finger trackpad swipe, which is a horizontal SCROLL a
// `DragGesture` cannot read. That cost the rows a shared container: SwiftUI
// scopes swipe bookkeeping to one `List`, so N rows in N lists had no way to
// retract each other, revealed actions piled up and survived a whole
// navigation round trip (#901); the per-row List also lost the leading edge
// to a tiled split view (the iPad leading-swipe saga) and made a background
// snapshot expensive enough to trip the scene-update watchdog.
//
// The 27 SDKs end the trade: the virtualized ScrollView is marked
// `.swipeActionsContainer()` (in `MessageListView+Selection`), and each row
// attaches `.swipeActions` directly to plain content. One container, so one
// reveal at a time and tap-elsewhere retracts; the system gesture on every
// platform, trackpad included (measured in the `swipe-repro` harness,
// 2026-08-01). The deployment target is 27 for this reason.
//
// The index-addressed virtualization REQUIRES every row to occupy exactly
// `rowHeight` (the scroll extent is `rowCount * rowHeight` and placeholders
// align to it -- see the `virtualizedList` doc comment), so the row is
// pinned with `.frame(height:)` and clipped.

/// One swipe action (leading or trailing). `tint` is the revealed
/// background; `perform` runs on tap / full-swipe. `identifier` is the
/// machine-facing `accessibilityIdentifier` for the revealed button —
/// stable across the title variants a spec can carry (Archive/Trash,
/// Read/Unread), so automation addresses the affordance, not the copy.
struct SwipeActionSpec {
    let systemImage: String
    let title: String
    let tint: Color
    let role: ButtonRole?
    let identifier: String?
    let perform: () -> Void

    init(
        systemImage: String,
        title: String,
        tint: Color,
        role: ButtonRole? = nil,
        identifier: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.role = role
        self.identifier = identifier
        self.perform = perform
    }
}

/// A fixed-height message row with leading / trailing swipe actions.
/// Clicking / tapping the row selects it (`onSelect`). Hosted in a
/// container marked `.swipeActionsContainer()`; on its own it is a plain
/// row with no swipe.
struct SwipeActionRow<Content: View>: View {
    let height: CGFloat
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        // The row's click target is a `Button`, not a bare `.onTapGesture`:
        // the row answers `AXPress`, so VoiceOver and automation can
        // activate it, matching the bulk-mode row, which has always been a
        // `Button` (#984).
        Button(action: onSelect) {
            content()
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                // Horizontal insets give the row its left/right breathing
                // room (matching `placeholderRow`); the selection background
                // below fills the full width, content sits inset.
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: height)
        .background(rowBackground)
        .clipped()
        .swipeActions(edge: .trailing) {
            if let trailing { swipeButton(trailing) }
        }
        .swipeActions(edge: .leading) {
            if let leading { swipeButton(leading) }
        }
    }

    @ViewBuilder
    private func swipeButton(_ spec: SwipeActionSpec) -> some View {
        Button(role: spec.role, action: spec.perform) {
            Label(spec.title, systemImage: spec.systemImage)
        }
        .tint(spec.tint)
        .accessibilityIdentifier(spec.identifier ?? "")
    }
}
