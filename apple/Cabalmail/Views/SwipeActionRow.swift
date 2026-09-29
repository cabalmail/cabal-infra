import SwiftUI

// Swipe actions for the virtualized message list, restored after the
// ScrollView+LazyVStack rework (`project_apple_list_virtualization`)
// dropped `List`-only `.swipeActions`.
//
// There are two paths, and which one a row takes is the OS it's running on.
//
// On iOS/macOS/visionOS 27 and later the row carries `.swipeActions` itself
// inside the outer `LazyVStack`, and the enclosing ScrollView carries
// `.swipeActionsContainer()` (applied by `coordinatedSwipeActionsContainer()`,
// below). The container makes the reveal mutually exclusive -- revealing one
// row retracts any other, and a tap on blank space inside the scroll view or
// a vertical scroll retracts it too (#901).
//
// Outside a `List`, though, SwiftUI 27 keeps each edge's swipe content from
// the row's FIRST build. The row publishes its actions as a preference that a
// per-row host copies into state, and the equality that gates the copy
// compares only the edge, `allowsFullSwipe` and which edges exist -- never
// the actions themselves. A `Button` built from this row's `SwipeActionSpec`
// therefore froze its caption AND its closure, and in an index-addressed list
// that closure held whichever `Envelope` first occupied the slot: read/unread
// stuck (#1747), actions silently no-opped on macOS, and after a list shift a
// swipe could act on a different message. That shape shipped in 1.22.2 and
// was reverted in 1.22.3.
//
// So the 27 path hands `.swipeActions` nothing that can go stale. Its content
// is a `LiveSwipeButton`, which stores only its edge and draws whatever spec
// the row publishes through the environment on every build -- published
// OUTSIDE the `.swipeActions` modifiers, which is what lets it reach the
// revealed buttons. The frozen part is then an empty shell around live data:
// caption, symbol, tint, role and closure all follow the row. Which edges
// carry a modifier at all is decided structurally, because presence is one of
// the few things that equality does see. `SwipeActionLiveContentTests` drives
// the real container on macOS and fails if a swipe runs a stale closure.
//
// On iPadOS the container's reveal answers touches only, so a trackpad's
// two-finger swipe revealed nothing there; on iOS the 27 path adds a trackpad
// half of its own (`TrackpadSwipe.swift`).
//
// Below 27 there is no container API, so each loaded row embeds a single-row
// `List` purely to borrow its native `.swipeActions`. Hand-rolling the gesture
// isn't an option (a SwiftUI `DragGesture` can't read the macOS two-finger
// trackpad swipe -- that's a horizontal SCROLL gesture, not a click-drag), and
// the borrowed List gets the real system swipe on every platform at once:
// macOS two-finger trackpad, iOS/iPadOS touch, visionOS. A `List` refreshes
// its swipe content on every build, so the freeze above doesn't apply there.
// But SwiftUI scopes swipe mutual exclusivity to one `List`, so N rows in N
// Lists have no shared state to retract each other: #901 is live on this path
// and stays live, because the deployment floor is iOS 18 / macOS 15 and there
// is nothing below 27 to fix it with.
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

extension SwipeActionSpec {
    /// The button a swipe reveals for this spec. Both paths draw it from here,
    /// so they can't drift apart.
    @MainActor
    var revealedButton: some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: systemImage)
        }
        .tint(tint)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// A fixed-height list row that reveals leading / trailing swipe actions
/// natively: on 27 and later through the enclosing
/// `.swipeActionsContainer()`, below it through a borrowed single-row `List`.
/// Clicking / tapping the row selects it (`onSelect`).
struct SwipeActionRow<Content: View>: View {
    let height: CGFloat
    /// What the row is showing. The list addresses rows by index, so one row
    /// shows a different message once the list shifts; a trackpad reveal
    /// belongs to the message and is dropped when this changes.
    let contentID: AnyHashable
    let rowBackground: Color
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let onSelect: () -> Void
    @ViewBuilder let content: () -> Content

    #if os(iOS)
    /// Present on 27 and later, inside `coordinatedSwipeActionsContainer()`.
    @Environment(TrackpadSwipeCoordinator.self) private var trackpadSwipes: TrackpadSwipeCoordinator?
    #endif

    var body: some View {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            containerRow
        } else {
            embeddedListRow
        }
    }

    /// 27 and later: the row carries `.swipeActions` itself, inside the outer
    /// `LazyVStack`, and the enclosing ScrollView's `.swipeActionsContainer()`
    /// supplies the one-row-at-a-time bookkeeping. With no embedded `List`
    /// there is nothing to zero out, nothing to keep out of the focus chain,
    /// and nothing scrolling its own clipped content. The horizontal padding
    /// mirrors the pre-27 path's `.listRowInsets`: content sits 16pt in from
    /// each edge while the selection background fills the row's full width.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private var containerRow: some View {
        swipeEdges(
            withTrackpadSwipes(
                rowButton
                    .padding(.horizontal, 16)
                    .frame(height: height)
                    .background(rowBackground)
            )
            .clipped()
        )
        // Outside the `.swipeActions` modifiers so it reaches the buttons they
        // reveal, and re-published on every build of this row -- the content
        // SwiftUI keeps from the first build reads it from here (see
        // `LiveSwipeButton`).
        .environment(\.swipeActionSpecs, SwipeActionSpecs(leading: leading, trailing: trailing))
    }

    /// One `.swipeActions` per edge that has a spec. The swipe content is kept
    /// from the first build and can't be emptied later, but adding or removing
    /// an edge's modifier is a change the container does see -- and Settings ›
    /// Actions can disable an edge mid-session.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @ViewBuilder
    private func swipeEdges(_ row: some View) -> some View {
        switch (leading != nil, trailing != nil) {
        case (true, true):
            row
                .swipeActions(edge: .trailing) { LiveSwipeButton(edge: .trailing) }
                .swipeActions(edge: .leading) { LiveSwipeButton(edge: .leading) }
        case (false, true):
            row.swipeActions(edge: .trailing) { LiveSwipeButton(edge: .trailing) }
        case (true, false):
            row.swipeActions(edge: .leading) { LiveSwipeButton(edge: .leading) }
        case (false, false):
            row
        }
    }

    /// iPadOS: the trackpad half of the 27 path's swipe, inside the clip so its
    /// reveal stays within the row. The container's own reveal answers touches
    /// only (see `TrackpadSwipe.swift`). Everywhere else the row passes through.
    @ViewBuilder
    private func withTrackpadSwipes(_ row: some View) -> some View {
        #if os(iOS)
        row.trackpadSwipeReveal(contentID: contentID, leading: leading, trailing: trailing, height: height)
        #else
        row
        #endif
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
            if let trailing { trailing.revealedButton }
        }
        .swipeActions(edge: .leading) {
            if let leading { leading.revealedButton }
        }
    }

    /// The row's click target is a `Button`, not a bare `.onTapGesture`.
    /// On macOS 27 a tap gesture inside the pre-27 path's list never receives
    /// the click -- a hosted control in the same stack does (#984) -- and a
    /// button is the honest shape anyway: the row answers `AXPress`, so
    /// VoiceOver and automation can activate it, matching the bulk-mode row,
    /// which has always been a `Button`. Shared by both paths.
    private var rowButton: some View {
        Button {
            #if os(iOS)
            // A click on another row retracts an open trackpad reveal, as a tap
            // does the container's own. (The revealed row's click never gets
            // here: its reveal takes it.)
            trackpadSwipes?.closeAll()
            #endif
            onSelect()
        } label: {
            content()
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The leading and trailing specs a `SwipeActionRow` publishes to the buttons
/// its swipes reveal.
struct SwipeActionSpecs {
    var leading: SwipeActionSpec?
    var trailing: SwipeActionSpec?

    subscript(edge: HorizontalEdge) -> SwipeActionSpec? {
        edge == .leading ? leading : trailing
    }
}

private struct SwipeActionSpecsKey: EnvironmentKey {
    // Computed rather than stored: a stored static of a type that holds
    // closures isn't concurrency-safe.
    static var defaultValue: SwipeActionSpecs { SwipeActionSpecs() }
}

extension EnvironmentValues {
    /// The specs of the `SwipeActionRow` a view sits in; read by
    /// `LiveSwipeButton`.
    var swipeActionSpecs: SwipeActionSpecs {
        get { self[SwipeActionSpecsKey.self] }
        set { self[SwipeActionSpecsKey.self] = newValue }
    }
}

/// The only view the 27 path hands `.swipeActions`, and deliberately empty of
/// row data: it stores its edge and nothing else, and draws the spec the row
/// publishes through `\.swipeActionSpecs` each time it renders.
///
/// SwiftUI keeps this view from the row's first build and never replaces it
/// (see the file comment), so a caption, symbol or closure stored here would
/// stay whatever that build captured. A new stored property is exactly the
/// regression #1747 was; `SwipeActionLiveContentTests` fails on one.
struct LiveSwipeButton: View {
    let edge: HorizontalEdge
    @Environment(\.swipeActionSpecs) private var specs

    var body: some View {
        if let spec = specs[edge] {
            spec.revealedButton
        }
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
    ///
    /// On iOS it also installs the coordinator for the rows' trackpad reveal
    /// (`TrackpadSwipe.swift`), which the native container knows nothing
    /// about.
    @ViewBuilder
    func coordinatedSwipeActionsContainer() -> some View {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            #if os(iOS)
            swipeActionsContainer()
                .trackpadSwipeCoordination()
            #else
            swipeActionsContainer()
            #endif
        } else {
            self
        }
    }
}
