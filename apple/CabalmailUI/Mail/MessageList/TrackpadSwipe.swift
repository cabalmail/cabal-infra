import SwiftUI
#if os(iOS)
import UIKit
#endif

// Trackpad two-finger swipes on the message list, iPadOS 27 and later.
//
// On 27 `SwipeActionRow` reveals its actions through SwiftUI's own
// `.swipeActions` outside a `List`, coordinated by `.swipeActionsContainer()`
// (#901). On iPadOS that reveal is driven by a `DragGesture`, which reads
// touches and nothing else. A two-finger swipe on a trackpad is not a touch:
// UIKit delivers it as scroll input, which only reaches gesture recognizers
// that opt into scroll types. On the 27 path it went to the enclosing scroll
// view -- which cannot scroll sideways -- and no row ever revealed. Below 27
// the borrowed per-row `List` gets it from UIKit's own swipe machinery, so the
// container brought the regression with it. macOS is unaffected: its container
// reads the trackpad's scroll events natively.
//
// SwiftUI has no API to open its reveal from code, so the trackpad half is
// drawn here: a scroll-only pan recognizer on each row that is never handed a
// touch (every touch stays with the native swipe), and a reveal that mirrors
// the container's -- the edge's action in a tinted capsule that fades and grows
// in, stretches with the swipe, settles at its natural width, and runs on a
// click. A long enough swipe runs it outright. `TrackpadSwipeCoordinator`,
// installed alongside the container, keeps it to one row at a time and
// retracts it on a scroll, a click on another row, or a click on the row
// itself, the way the container treats its own reveal.
//
// The rules are `TrackpadSwipePolicy` and each row's `TrackpadSwipeTracker`,
// kept apart from the view so they can be tested without synthesizing scroll
// input: only XCUITest can do that (SimDrive's `pscroll` verb drives the real
// thing in a simulator), and SwiftUI attaches the recognizer to a view only
// once an event arrives, so an in-process test cannot even find it.

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

#if os(iOS)

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

    /// The trackpad half of a row's swipe actions (see the file comment).
    /// `contentID` names what the row shows; a reveal belongs to it and is
    /// dropped when the row is re-pointed at another message.
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
    func began(coordinator: TrackpadSwipeCoordinator?) {
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
            .gesture(
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
                    onCancelled: { tracker.close(coordinator: coordinator) }
                )
            )
            // Index-addressed rows re-point when the list shifts.
            .onChange(of: contentID) { tracker.reset(coordinator: coordinator) }
            .onChange(of: coordinator?.owner) { _, owner in tracker.ownerChanged(to: owner) }
            .onChange(of: leading == nil) { tracker.edgesChanged(row: row, coordinator: coordinator) }
            .onChange(of: trailing == nil) { tracker.edgesChanged(row: row, coordinator: coordinator) }
    }

    /// UIKit reports movement in screen terms; the tracker works in the row's
    /// layout direction.
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

// MARK: - The recognizer

/// A pan that sees trackpad scrolling and nothing else.
///
/// `allowedTouchTypes` is empty, so it is never handed a touch -- every touch
/// stays with the native swipe, the row's button, and the list's own
/// scrolling, and none of them is ever asked to wait for it. It takes
/// `.continuous` scroll input only: a trackpad's two-finger swipe (and a Magic
/// Mouse's surface), not a wheel's discrete steps.
struct TrackpadSwipeRecognizer: UIGestureRecognizerRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void
    let onCancelled: () -> Void

    /// The recognizer as installed, minus its delegate. Separate so tests can
    /// read the configuration that decides which input it sees.
    static func configuredRecognizer() -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.allowedTouchTypes = []
        pan.allowedScrollTypesMask = .continuous
        pan.name = "cabalmail.trackpadSwipe"
        return pan
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = Self.configuredRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            onBegan()
            onChanged(translation)
        case .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Delegate {
        Delegate()
    }

    final class Delegate: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            let velocity = pan.velocity(in: pan.view)
            return TrackpadSwipePolicy.beginsSwipe(
                translation: CGSize(width: translation.x, height: translation.y),
                velocity: CGSize(width: velocity.x, height: velocity.y)
            )
        }

        /// The list's scroll view takes trackpad scrolling too, and would start
        /// scrolling on a swipe's slight vertical wobble. It waits for this pan
        /// to decide, which it does on the first movement: a vertical scroll
        /// fails here at once and goes on to scroll the list.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}
#endif
