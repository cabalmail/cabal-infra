import SwiftUI

// Swipe actions for the virtualized message list, restored after the
// ScrollView+LazyVStack rework (`project_apple_list_virtualization`)
// dropped `List`-only `.swipeActions`.
//
// There are two paths, and which one a row takes is the OS it's running on.
//
// On iOS/macOS/visionOS 27 and later the row is just a row: `.swipeActions`
// sits directly on it inside the outer `LazyVStack`, and the enclosing
// ScrollView carries `.swipeActionsContainer()` (applied by
// `coordinatedSwipeActionsContainer()`, see below) to scope the gesture and
// its bookkeeping to the whole list. The container is what makes the reveal
// mutually exclusive -- revealing one row retracts any other, a tap on blank
// space inside the scroll view retracts, and so does a vertical scroll (#901).
//
// Below 27 there is no container API, so each loaded row embeds a single-row
// `List` purely to borrow its native `.swipeActions`. Hand-rolling the gesture
// isn't an option (a SwiftUI `DragGesture` can't read the macOS two-finger
// trackpad swipe -- that's a horizontal SCROLL gesture, not a click-drag), and
// the borrowed List gets the real system swipe on every platform at once:
// macOS two-finger trackpad, iOS/iPadOS touch, visionOS. SwiftUI scopes swipe
// mutual exclusivity to one `List`, though, so N rows in N Lists have no
// shared state to retract each other: #901 is live on this path and stays
// live, because the deployment floor is iOS 18 / macOS 15 and there is nothing
// below 27 to fix it with.
//
// The index-addressed virtualization REQUIRES every row to occupy exactly
// `rowHeight` (the scroll extent is `rowCount * rowHeight` and placeholders
// align to it -- see the `virtualizedList` doc comment), so BOTH paths pin the
// row with `.frame(height:).clipped()`. On the pre-27 path that also contains
// the List's own insets / min-row-height / chrome: whatever the List does
// internally, the row's footprint in the outer `LazyVStack` stays exactly
// `rowHeight`, matching the placeholder rows. Inset/separator/background are
// zeroed so the content fills that height rather than sitting inside List
// padding.

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

/// A fixed-height list row that reveals leading / trailing swipe actions
/// natively: on 27 and later through the enclosing
/// `.swipeActionsContainer()`, below it through a borrowed single-row `List`.
/// Clicking / tapping the row selects it (`onSelect`).
struct SwipeActionRow<Content: View>: View {
    let height: CGFloat
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            containerRow
        } else {
            embeddedListRow
        }
    }

    /// 27 and later: the row carries `.swipeActions` itself, inside the outer
    /// `LazyVStack`, and the enclosing ScrollView's `.swipeActionsContainer()`
    /// supplies the gesture and the one-row-at-a-time bookkeeping. With no
    /// embedded `List` there is nothing to zero out, nothing to keep out of the
    /// focus chain, and nothing scrolling its own clipped content. The
    /// horizontal padding mirrors the pre-27 path's `.listRowInsets`: content
    /// sits 16pt in from each edge while the selection background fills the
    /// row's full width.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private var containerRow: some View {
        rowButton
            .padding(.horizontal, 16)
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

    /// Below 27: the borrowed single-row `List`. #901 (several rows revealed at
    /// once, nothing retracts them) is inherent to this path -- see the file
    /// comment.
    private var embeddedListRow: some View {
        List {
            listRowContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // Zero the List's own content insets on both axes (they differ by
        // platform) so the row's geometry is driven solely by `height` + the
        // explicit row insets below, not by hidden List padding.
        .contentMargins(.all, 0, for: .scrollContent)
        // NOT `.scrollDisabled(true)`: on macOS the swipe IS a two-finger
        // scroll gesture, and disabling scroll suppresses it. Instead the
        // single row exactly fills the frame, so there's no vertical overflow
        // to scroll; `.basedOnSize` drops the bounce so a vertical two-finger
        // pass-through reaches the outer ScrollView while the horizontal swipe
        // stays live for `.swipeActions`.
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.defaultMinListRowHeight, height)
        // A List is focusable and arrow-navigable; left alone, each per-row
        // List would compete with the outer ScrollView for keyboard focus and
        // swallow Up/Down. Drop it from the focus chain so the outer list owns
        // keyboard navigation.
        .focusable(false)
        .frame(height: height)
        .clipped()
    }

    private var listRowContent: some View {
        rowButton
        // Horizontal insets give the row its left/right breathing room
        // (matching `placeholderRow`); vertical stays 0 so `height` alone
        // sets the row height. The selection background fills the full
        // width (it's a separate `listRowBackground`), content sits inset.
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(rowBackground)
        .swipeActions(edge: .trailing) {
            if let trailing { swipeButton(trailing) }
        }
        .swipeActions(edge: .leading) {
            if let leading { swipeButton(leading) }
        }
    }

    /// The row's click target is a `Button`, not a bare `.onTapGesture`.
    /// On macOS 27 a tap gesture inside the pre-27 path's list never receives
    /// the click -- a hosted control in the same stack does (#984) -- and a
    /// button is the honest shape anyway: the row answers `AXPress`, so
    /// VoiceOver and automation can activate it, matching the bulk-mode row,
    /// which has always been a `Button`. Shared by both paths.
    private var rowButton: some View {
        Button(action: onSelect) {
            content()
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

extension View {
    /// Scopes swipe-action coordination to this container on 27 and later, and
    /// does nothing below it.
    ///
    /// Applied to the scroll view that holds `SwipeActionRow`s. Without it the
    /// 27 path still reveals (the gesture needs no container) but nothing ever
    /// retracts -- strictly worse than #901, where at least the swiped row's
    /// own tap retracts it. The two therefore ship together: a row that drops
    /// its embedded `List` needs a container above it, and
    /// `SwipeActionContainerSourceScanTests` pins the pairing.
    @ViewBuilder
    func coordinatedSwipeActionsContainer() -> some View {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            swipeActionsContainer()
        } else {
            self
        }
    }
}
