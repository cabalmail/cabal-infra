import SwiftUI
import CabalmailKit

// A swipe reveal the message list draws itself, on 27 and later, for the one
// input the native container misses on each platform that draws one
// (`HostPlatform.drawsRowSwipeReveal`): a trackpad's two-finger swipe on
// iPadOS, and a finger on a Mac's touch display. The iPadOS case came first,
// and the names below are its; the input itself is `TrackpadSwipeRecognizer`
// (`Platform/`), whichever it is.
//
// On 27 `SwipeActionRow` reveals its actions through SwiftUI's own
// `.swipeActions` outside a `List`, coordinated by `.swipeActionsContainer()`
// (#901). On iPadOS that reveal is driven by a `DragGesture`, which reads
// touches and nothing else. A two-finger swipe on a trackpad is not a touch:
// UIKit delivers it as scroll input, which only reaches gesture recognizers
// that opt into scroll types. On the 27 path it went to the enclosing scroll
// view -- which cannot scroll sideways -- and no row ever revealed. Below 27
// the borrowed per-row `List` gets it from UIKit's own swipe machinery, so the
// container brought the regression with it.
//
// On macOS it is the other way round: the container's reveal answers the
// trackpad's scroll events and nothing else, and AppKit hands a finger on the
// display only to gesture recognizers, so on the touchscreen MacBook Pro a
// swipe on a message revealed nothing (feed rows, plain `List` rows, swipe
// under a finger). There the recognizer takes direct touches only, and the
// trackpad stays with the container.
//
// SwiftUI has no API to open its reveal from code, so the missing half is
// drawn here: a pan recognizer on each row that sees only the input the
// container misses (everything else stays with it), and a reveal that mirrors
// the container's -- the edge's action in a tinted capsule that fades and grows
// in, stretches with the swipe, settles at its natural width, and runs on a
// click. A long enough swipe runs it outright. `TrackpadSwipeCoordinator`,
// installed alongside the container, keeps it to one row at a time and
// retracts it on a scroll, a click on another row, or a click on the row
// itself, the way the container treats its own reveal.
//
// The rules are `TrackpadSwipePolicy` and each row's `TrackpadSwipeTracker`,
// kept apart from the view so they can be tested without synthesizing the
// input: only XCUITest can do that on iPadOS (SimDrive's `pscroll` verb drives
// the real thing in a simulator), nothing in-process can make a direct touch
// on macOS, and SwiftUI attaches the recognizer to a view only once an event
// arrives, so an in-process test cannot even find it.

/// How a trackpad swipe ends when the fingers lift.
enum TrackpadSwipeOutcome: Equatable {
    /// Back to rest.
    case closed
    /// Revealed: the edge's action waits for a click.
    case open(HorizontalEdge)
    /// Swiped far enough to run the edge's action without a click.
    case run(HorizontalEdge)
}

/// The trackpad swipe's rules, independent of UIKit and of any view.
///
/// Offsets are in the row's own layout direction: positive moves the row's
/// content toward its trailing edge and reveals the LEADING action, negative
/// reveals the trailing one.
enum TrackpadSwipePolicy {
    /// Gap between a revealed capsule and the row's edge, and between the
    /// capsule and the content it pushed aside -- the container's own spacing.
    static let capsuleInset: CGFloat = 8

    /// Gap above and below the capsule; the container draws a 50pt capsule in
    /// a 58pt row.
    static let capsuleVerticalInset: CGFloat = 4

    /// A lift faster than this, in points per second, settles in the direction
    /// of travel whatever the distance: a flick open opens, a flick back closes.
    static let flickVelocity: CGFloat = 400

    /// Whether a pan's opening movement is a row swipe. Horizontal-dominant
    /// only, so a vertical two-finger scroll that strays sideways stays with the
    /// list. UIKit may ask before any translation accrues, so velocity decides
    /// when the translation is still zero.
    static func beginsSwipe(translation: CGSize, velocity: CGSize) -> Bool {
        if translation != .zero {
            return abs(translation.width) > abs(translation.height)
        }
        return abs(velocity.width) > abs(velocity.height)
    }

    /// A finger on a Mac's touch display both scrolls the list and swipes a
    /// row, so its axis is read off the movement itself: nothing until it
    /// has travelled `axisDecisionDistance`, then a swipe if mostly sideways,
    /// and a scroll otherwise, for the rest of that touch.
    enum TouchAxis: Equatable {
        case swipe
        case scroll
    }

    /// How far a finger travels before its axis is decided.
    static let axisDecisionDistance: CGFloat = 8

    /// The axis of a finger that has moved by `translation`, or nil while it
    /// is too short to tell.
    static func touchAxis(translation: CGSize) -> TouchAxis? {
        guard max(abs(translation.width), abs(translation.height)) >= axisDecisionDistance else { return nil }
        return abs(translation.width) > abs(translation.height) ? .swipe : .scroll
    }

    /// How far a swipe travels before lifting runs the action instead of
    /// revealing it. The 27 container's own threshold measured about 300pt on
    /// iPad and iPhone rows alike (#901's probe); capped at three quarters of
    /// the row so a narrow list column can still reach it.
    static func runDistance(rowWidth: CGFloat) -> CGFloat {
        min(300, rowWidth * 0.75)
    }

    /// The offset a revealed edge settles at: its capsule plus an inset on
    /// either side.
    static func revealOffset(capsuleWidth: CGFloat) -> CGFloat {
        capsuleWidth + 2 * capsuleInset
    }

    /// The content's offset while the fingers are down: where it started plus
    /// how far they have moved, pinned to rest on a side with no action and
    /// never further than the row is wide.
    static func trackedOffset(
        from start: CGFloat,
        translation: CGFloat,
        hasLeading: Bool,
        hasTrailing: Bool,
        rowWidth: CGFloat
    ) -> CGFloat {
        var offset = start + translation
        if offset > 0, !hasLeading { offset = 0 }
        if offset < 0, !hasTrailing { offset = 0 }
        return min(max(offset, -rowWidth), rowWidth)
    }

    /// Where the swipe settles when the fingers lift at `offset` moving at
    /// `velocity`, for an edge whose capsule reveals at `revealOffset`.
    static func outcome(
        offset: CGFloat,
        velocity: CGFloat,
        revealOffset: CGFloat,
        rowWidth: CGFloat
    ) -> TrackpadSwipeOutcome {
        guard offset != 0 else { return .closed }
        let edge: HorizontalEdge = offset > 0 ? .leading : .trailing
        let distance = abs(offset)
        // Positive while the content is still travelling away from rest.
        let opening = offset > 0 ? velocity : -velocity
        if distance >= runDistance(rowWidth: rowWidth) { return .run(edge) }
        if opening > flickVelocity { return .open(edge) }
        if opening < -flickVelocity { return .closed }
        return distance > revealOffset / 2 ? .open(edge) : .closed
    }
}

// MARK: - Coordination

/// Which row's trackpad reveal is open, so there is only ever one. Owned by
/// `coordinatedSwipeActionsContainer()` and read by every row inside it.
///
/// Rows are identified by a token of their own rather than by message: the
/// same UID can appear twice in a cross-folder search.
///
/// Every write is guarded: Observation notifies on any assignment, equal or
/// not, and `closeAll()` runs on every row click and scroll phase -- each
/// visible row would re-run its reveal for nothing.
@MainActor
@Observable
final class TrackpadSwipeCoordinator {
    /// The row whose reveal is open or tracking, if any.
    private(set) var owner: UUID?

    /// A row's swipe began: every other reveal retracts.
    func claim(_ row: UUID) {
        if owner != row { owner = row }
    }

    /// A row closed its own reveal.
    func release(_ row: UUID) {
        if owner == row { owner = nil }
    }

    /// Retract whatever is open -- a scroll, or a click elsewhere in the list.
    func closeAll() {
        if owner != nil { owner = nil }
    }
}

extension View {
    /// Installs the trackpad coordinator for the rows inside this scroll view,
    /// and retracts their reveal when it scrolls. Applied by
    /// `coordinatedSwipeActionsContainer()` next to the native container.
    func trackpadSwipeCoordination() -> some View {
        modifier(TrackpadSwipeCoordination())
    }

    /// The drawn half of a row's swipe actions (see the file comment).
    /// `contentID` names what the row shows; a reveal belongs to it and is
    /// dropped when the row is re-pointed at another message.
    @available(macOS 27.0, *)
    func trackpadSwipeReveal(
        contentID: AnyHashable,
        leading: SwipeActionSpec?,
        trailing: SwipeActionSpec?,
        height: CGFloat
    ) -> some View {
        modifier(TrackpadSwipeReveal(contentID: contentID, leading: leading, trailing: trailing, height: height))
    }
}

private struct TrackpadSwipeCoordination: ViewModifier {
    @State private var coordinator = TrackpadSwipeCoordinator()

    func body(content: Content) -> some View {
        content
            .environment(coordinator)
            // The container retracts its own reveal the same way.
            .onScrollPhaseChange { _, phase in
                if phase != .idle { coordinator.closeAll() }
            }
    }
}

// MARK: - The row's reveal

/// A row's trackpad reveal: where its content sits, and what each phase of a
/// swipe does to it. The view draws it and feeds it the recognizer's phases;
/// every decision a swipe makes happens here, so tests can drive it without
/// scroll input.
@MainActor
@Observable
final class TrackpadSwipeTracker {
    /// What the tracker needs to know about its row at each step.
    struct Row {
        var leading: SwipeActionSpec?
        var trailing: SwipeActionSpec?
        /// The row's width, which bounds a swipe.
        var width: CGFloat
        /// Where each edge's reveal settles (`TrackpadSwipePolicy.revealOffset`).
        var leadingReveal: CGFloat
        var trailingReveal: CGFloat

        func spec(for edge: HorizontalEdge) -> SwipeActionSpec? {
            edge == .leading ? leading : trailing
        }

        func reveal(for edge: HorizontalEdge) -> CGFloat {
            edge == .leading ? leadingReveal : trailingReveal
        }
    }

    /// The content's offset (see `TrackpadSwipePolicy`).
    private(set) var offset: CGFloat = 0
    /// The offset a swipe in progress started from; nil at rest.
    private(set) var trackingFrom: CGFloat?
    /// This row, to the coordinator.
    let token = UUID()

    @ObservationIgnored private let settle = Animation.snappy(duration: 0.25)

    /// Translations and velocities below are in the row's layout direction.
    ///
    /// A second `began` before the swipe ends is ignored, and so is an
    /// `ended` that no `began` opened: the Mac's input is a SwiftUI drag that
    /// keeps no state of its own and reports a swipe as it becomes one
    /// (`TrackpadSwipeRecognizer`).
    func began(coordinator: TrackpadSwipeCoordinator?) {
        guard trackingFrom == nil else { return }
        trackingFrom = offset
        coordinator?.claim(token)
    }

    func changed(translation: CGFloat, row: Row) {
        guard let start = trackingFrom else { return }
        offset = TrackpadSwipePolicy.trackedOffset(
            from: start,
            translation: translation,
            hasLeading: row.leading != nil,
            hasTrailing: row.trailing != nil,
            rowWidth: row.width
        )
    }

    func ended(translation: CGFloat, velocity: CGFloat, row: Row, coordinator: TrackpadSwipeCoordinator?) {
        guard trackingFrom != nil else { return }
        changed(translation: translation, row: row)
        trackingFrom = nil
        let edge: HorizontalEdge = offset >= 0 ? .leading : .trailing
        switch TrackpadSwipePolicy.outcome(
            offset: offset,
            velocity: velocity,
            revealOffset: row.reveal(for: edge),
            rowWidth: row.width
        ) {
        case .closed:
            close(coordinator: coordinator)
        case .open(let edge):
            withAnimation(settle) {
                offset = edge == .leading ? row.leadingReveal : -row.trailingReveal
            }
        case .run(let edge):
            run(row.spec(for: edge), coordinator: coordinator)
        }
    }

    /// The revealed capsule was clicked, or a swipe ran long: retract, then act.
    func run(_ spec: SwipeActionSpec?, coordinator: TrackpadSwipeCoordinator?) {
        close(coordinator: coordinator)
        spec?.perform()
    }

    /// The input gave up on a swipe in progress: retract it. After a swipe
    /// that ended cleanly there is nothing in progress, and an open reveal
    /// stays open. On macOS a SwiftUI drag that SwiftUI cancels reports no
    /// end at all, and left the row tracking -- deaf to its next swipe
    /// (`began` is ignored while tracking) and to retraction by another row
    /// -- until it showed another message; the Mac's input reports the
    /// cancel through its gesture state (`rowSwipeInput`).
    func cancel(coordinator: TrackpadSwipeCoordinator?) {
        guard trackingFrom != nil else { return }
        CabalmailLog.info("RowSwipe", "A swipe in progress was cancelled; retracting the row")
        close(coordinator: coordinator)
    }

    func close(coordinator: TrackpadSwipeCoordinator?) {
        trackingFrom = nil
        if offset != 0 {
            withAnimation(settle) { offset = 0 }
        }
        coordinator?.release(token)
    }

    /// The row now shows another message: the reveal belonged to the one that
    /// left, so it goes at once, unanimated.
    func reset(coordinator: TrackpadSwipeCoordinator?) {
        trackingFrom = nil
        offset = 0
        coordinator?.release(token)
    }

    /// Another row's swipe began, or the list retracted everything. A swipe
    /// still under this row's fingers keeps going.
    func ownerChanged(to owner: UUID?) {
        guard owner != token, trackingFrom == nil, offset != 0 else { return }
        withAnimation(settle) { offset = 0 }
    }

    /// Settings > Actions can take an edge away mid-session; a reveal of that
    /// edge goes with it.
    func edgesChanged(row: Row, coordinator: TrackpadSwipeCoordinator?) {
        if (offset > 0 && row.leading == nil) || (offset < 0 && row.trailing == nil) {
            close(coordinator: coordinator)
        }
    }
}

@available(macOS 27.0, *)
private struct TrackpadSwipeReveal: ViewModifier {
    let contentID: AnyHashable
    let leading: SwipeActionSpec?
    let trailing: SwipeActionSpec?
    let height: CGFloat

    @Environment(TrackpadSwipeCoordinator.self) private var coordinator: TrackpadSwipeCoordinator?
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var tracker = TrackpadSwipeTracker()
    @State private var rowWidth: CGFloat = 0
    /// Each edge's capsule at its natural size, measured off screen.
    @State private var leadingCapsuleWidth: CGFloat = 0
    @State private var trailingCapsuleWidth: CGFloat = 0

    private var row: TrackpadSwipeTracker.Row {
        TrackpadSwipeTracker.Row(
            leading: leading,
            trailing: trailing,
            width: rowWidth,
            leadingReveal: TrackpadSwipePolicy.revealOffset(capsuleWidth: leadingCapsuleWidth),
            trailingReveal: TrackpadSwipePolicy.revealOffset(capsuleWidth: trailingCapsuleWidth)
        )
    }

    func body(content: Content) -> some View {
        content
            // While revealed, a click on the row retracts the reveal instead of
            // selecting it, as a tap does the container's.
            .overlay {
                if tracker.offset != 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { tracker.close(coordinator: coordinator) }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: tracker.offset)
            .background(alignment: .leading) { capsule(for: .leading) }
            .background(alignment: .trailing) { capsule(for: .trailing) }
            .background { measurements }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            .rowSwipeInput(
                TrackpadSwipeRecognizer(
                    onBegan: { tracker.began(coordinator: coordinator) },
                    onChanged: { tracker.changed(translation: logical($0), row: row) },
                    onEnded: { translation, velocity in
                        tracker.ended(
                            translation: logical(translation),
                            velocity: logical(velocity),
                            row: row,
                            coordinator: coordinator
                        )
                    },
                    onCancelled: { tracker.cancel(coordinator: coordinator) }
                )
            )
            // Index-addressed rows re-point when the list shifts.
            .onChange(of: contentID) { tracker.reset(coordinator: coordinator) }
            .onChange(of: coordinator?.owner) { _, owner in tracker.ownerChanged(to: owner) }
            .onChange(of: leading == nil) { tracker.edgesChanged(row: row, coordinator: coordinator) }
            .onChange(of: trailing == nil) { tracker.edgesChanged(row: row, coordinator: coordinator) }
    }

    /// The recognizer reports movement in screen terms; the tracker works in
    /// the row's layout direction.
    private func logical(_ physical: CGFloat) -> CGFloat {
        layoutDirection == .rightToLeft ? -physical : physical
    }

    /// The capsule in the gap the content left, centred in it: scaled and
    /// faded in until the gap reaches its settled width, stretched beyond it.
    @ViewBuilder
    private func capsule(for edge: HorizontalEdge) -> some View {
        let gap = edge == .leading ? max(tracker.offset, 0) : max(-tracker.offset, 0)
        if let spec = row.spec(for: edge), gap > 0 {
            let natural = edge == .leading ? leadingCapsuleWidth : trailingCapsuleWidth
            let progress = min(gap / row.reveal(for: edge), 1)
            Button(role: spec.role) {
                tracker.run(spec, coordinator: coordinator)
            } label: {
                TrackpadSwipeCapsuleLabel(spec: spec)
                    .frame(
                        width: max(natural, gap - 2 * TrackpadSwipePolicy.capsuleInset),
                        height: max(height - 2 * TrackpadSwipePolicy.capsuleVerticalInset, 0)
                    )
                    .background(Capsule().fill(spec.tint))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .scaleEffect(progress)
            .opacity(progress)
            .frame(width: gap)
            .accessibilityIdentifier(spec.identifier ?? "")
        }
    }

    /// Both capsules at their natural width, hidden, so a reveal knows where to
    /// settle before it is ever drawn.
    private var measurements: some View {
        ZStack {
            if let leading {
                TrackpadSwipeCapsuleLabel(spec: leading)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingCapsuleWidth = $0 }
            }
            if let trailing {
                TrackpadSwipeCapsuleLabel(spec: trailing)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingCapsuleWidth = $0 }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

/// The capsule's content: the action's symbol and title, drawn the way the
/// container draws its own -- filled symbol, medium footnote type.
private struct TrackpadSwipeCapsuleLabel: View {
    let spec: SwipeActionSpec

    var body: some View {
        Label(spec.title, systemImage: spec.systemImage)
            .labelStyle(.titleAndIcon)
            .symbolVariant(.fill)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 12)
    }
}
