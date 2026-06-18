import SwiftUI

// Swipe actions for the virtualized message list, restored after the
// ScrollView+LazyVStack rework (`project_apple_list_virtualization`)
// dropped `List`-only `.swipeActions`.
//
// Rather than hand-roll the gesture (a SwiftUI `DragGesture` can't read the
// macOS two-finger trackpad swipe -- that's a horizontal SCROLL gesture, not
// a click-drag), each loaded row embeds a single-row `List` purely to borrow
// its native `.swipeActions`. That gets the real system swipe on every
// platform at once: macOS two-finger trackpad, iOS/iPadOS touch, visionOS --
// identical to the pre-virtualization list and to system Mail.
//
// The index-addressed virtualization REQUIRES every row to occupy exactly
// `rowHeight` (the scroll extent is `rowCount * rowHeight` and placeholders
// align to it -- see the `virtualizedList` doc comment). A `List` carries its
// own insets / min-row-height / chrome, so the wrapper is pinned with
// `.frame(height:).clipped()`: whatever the List does internally, the row's
// footprint in the outer `LazyVStack` stays exactly `rowHeight`, matching the
// placeholder rows. Inset/separator/background are zeroed so the content
// fills that height rather than sitting inside List padding.

/// One swipe action (leading or trailing). `tint` is the revealed
/// background; `perform` runs on tap / full-swipe.
struct SwipeActionSpec {
    let systemImage: String
    let title: String
    let tint: Color
    let role: ButtonRole?
    let perform: () -> Void

    init(
        systemImage: String,
        title: String,
        tint: Color,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.role = role
        self.perform = perform
    }
}

/// A fixed-height list row that reveals leading / trailing swipe actions
/// via a borrowed single-row `List`. A tap selects the row (`onSelect`).
struct SwipeActionRow<Content: View>: View {
    let height: CGFloat
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        List {
            rowContent
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // NOT `.scrollDisabled(true)`: on macOS the swipe IS a two-finger
        // scroll gesture, and disabling scroll suppresses it. Instead the
        // single row exactly fills the frame, so there's no vertical overflow
        // to scroll; `.basedOnSize` drops the bounce so a vertical two-finger
        // pass-through reaches the outer ScrollView while the horizontal swipe
        // stays live for `.swipeActions`.
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.defaultMinListRowHeight, height)
        .frame(height: height)
        .clipped()
    }

    private var rowContent: some View {
        content()
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(rowBackground)
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
    }
}
