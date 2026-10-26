import SwiftUI

/// Whether this build compiled the iOS 27.1 fold code.
///
/// Every Duo API sits behind `#if os(iOS) && canImport(SwiftUICore,
/// _version: 8.0.85)` and `#available(iOS 27.1, *)`: the deployment target
/// is iOS 18, and the compiler version cannot tell the 27.0 SDK from 27.1
/// (both are Swift 6.4), so the guard reads SwiftUICore's module version
/// (8.0.84 in 27.0, 8.0.85 from 27.1). A build with an older Xcode compiles
/// the guarded code out without a word, and the app then runs boxed in on
/// both of the Duo's displays with no fold handling at all. The iOS-hosted
/// suite asserts this is true (`FoldAPICompiledTests`), so CI turns red the
/// day its Xcode stops compiling the guarded code.
enum FoldAPI {
    static let isCompiled: Bool = {
        #if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)
        return true
        #else
        return false
        #endif
    }()

    /// The confirming pass the fold waits for: a moment after a geometry
    /// callback, long enough for the next frames to replace a stale one,
    /// short enough not to be seen beside the 0.05 to 0.4 s the region
    /// itself takes to appear once the hinge rests. A starting value, as the
    /// spec's timings are.
    static let confirmDelay = Duration.milliseconds(50)
}

extension EnvironmentValues {
    /// The window's fold (`FoldState`), published by `foldGeometry()` at a
    /// main window's root. `.none` everywhere else, and on every host but an
    /// iPhone Duo held partly open.
    @Entry var foldState: FoldState = .none
    /// Whether the root has a newer fold reading than `foldState` that has
    /// not settled yet, so `onFoldPiecesChange(_:)` waits for it rather than
    /// pairing its own new frame with the window's old fold.
    @Entry var foldIsSettling = false
}

extension View {
    /// Publishes the window's fold to everything beneath as `\.foldState`.
    /// Applied once, at the root of a main window (`SignedInRootView`).
    ///
    /// On iOS 27.1 it reads the active division region on every layout pass,
    /// from a reader behind the view that spans the whole window, and the
    /// hinge from `onHingeChange`, and publishes the fold once two passes
    /// agree (`FoldSettler`) and through the hinge hold (`FoldHold`).
    /// Elsewhere it publishes `.none`.
    func foldGeometry() -> some View {
        modifier(FoldGeometryModifier())
    }

    /// Calls `action` with this view's bounds less the window's fold
    /// (`FoldPieces`) whenever they change, once two layout passes agree and
    /// the window's own fold has settled. Apply it to the view whose bounds
    /// something floats over, inside the safe area if that is where the
    /// floating thing may go, within the main window's own hierarchy (a
    /// sheet's frame has not been measured against the window's). Needs
    /// `foldGeometry()` above it; without it, the pieces are always whole.
    func onFoldPiecesChange(_ action: @escaping (FoldPieces) -> Void) -> some View {
        modifier(FoldPiecesReader(action: action))
    }
}

/// The window's fold, as settled and held: what `foldGeometry()` publishes.
@MainActor @Observable
final class FoldTracker {
    private(set) var state: FoldState = .none
    /// The latest layout pass read something that has not settled yet.
    private(set) var isSettling = false

    @ObservationIgnored private var settler = FoldSettler<FoldSample>()
    @ObservationIgnored private var hold: FoldHold
    @ObservationIgnored private var latest: FoldSample?
    @ObservationIgnored private var confirming: Task<Void, Never>?
    @ObservationIgnored private var waiting: Task<Void, Never>?
    @ObservationIgnored private var waitingFor: TimeInterval?
    private let now: () -> TimeInterval
    private let confirmDelay: Duration

    /// - Parameters:
    ///   - now: a monotonic clock in seconds; the system uptime in the app.
    ///   - confirmDelay: how long after a layout pass its confirming pass
    ///     runs.
    ///   - grace: how long a fold outlives its region with the hinge at rest
    ///     (`FoldHold.grace`).
    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        confirmDelay: Duration = FoldAPI.confirmDelay,
        grace: TimeInterval = FoldHold.defaultGrace
    ) {
        self.now = now
        self.confirmDelay = confirmDelay
        hold = FoldHold(grace: grace)
    }

    /// One layout pass's reading of the region and the window.
    func layoutPass(_ sample: FoldSample) {
        latest = sample
        settle(sample)
        noteSettling()
        confirming?.cancel()
        confirming = Task { [weak self, confirmDelay] in
            try? await Task.sleep(for: confirmDelay)
            guard !Task.isCancelled, let self, let latest = self.latest else { return }
            self.settle(latest)
            self.noteSettling()
        }
    }

    private func noteSettling() {
        let settling = latest != settler.settled
        if isSettling != settling {
            isSettling = settling
        }
    }

    func hingeChanged(_ reading: HingeReading?) {
        hold.hingeChanged(reading, at: now())
        publish()
    }

    private func settle(_ sample: FoldSample) {
        guard let settled = settler.pass(sample) else { return }
        hold.observe(settled, at: now())
        publish()
    }

    private func publish() {
        if state != hold.state {
            state = hold.state
        }
        // The hinge reports every 30 to 40 ms while it moves, and each report
        // can push the deadline back; only a different deadline restarts the
        // wait.
        guard hold.deadline != waitingFor else { return }
        waiting?.cancel()
        waitingFor = hold.deadline
        guard let deadline = hold.deadline else { return }
        let delay = max(0, deadline - now())
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.waitingFor = nil
            self.hold.tick(at: self.now())
            self.publish()
        }
    }
}

private struct FoldGeometryModifier: ViewModifier {
    @State private var tracker = FoldTracker()

    func body(content: Content) -> some View {
        content
            .modifier(FoldInputs(tracker: tracker))
            .environment(\.foldState, tracker.state)
            .environment(\.foldIsSettling, tracker.isSettling)
    }
}

#if os(iOS) && canImport(SwiftUICore, _version: 8.0.85)
/// Where the fold readings come from on iOS 27.1: the active division
/// regions in the window's geometry, filtered to the active ones explicitly
/// (Apple's reference once said inactive ones come back too; the runtime
/// returns only active ones by default, and the filter costs nothing), and
/// the hinge, read only while a fold is held, since that is all it is for.
///
/// The regions come from a clear reader behind the content that ignores
/// every safe area, the keyboard's included, not from the content itself.
/// The query returns only regions that overlap the view it is asked of, and
/// the content shrinks above the keyboard: in laptop pose the keyboard fills
/// the bottom half from the top of the crease, so the content would stop
/// overlapping it and the fold would end while the device is still folded.
private struct FoldInputs: ViewModifier {
    let tracker: FoldTracker

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content
                .background {
                    Color.clear
                        .onGeometryChange(for: FoldSample.self) { proxy in
                            Self.sample(proxy)
                        } action: { sample in
                            tracker.layoutPass(sample)
                        }
                        .ignoresSafeArea()
                }
                .onHingeChange(isEnabled: tracker.state.isFolded) { _, new in
                    tracker.hingeChanged(new.hinge.map(HingeReading.init))
                }
        } else {
            content
        }
    }

    /// The region in window coordinates, and the window's size: the
    /// reader's own, since it spans the window whatever the keyboard or the
    /// bar strip does to the safe area.
    @available(iOS 27.1, *)
    nonisolated private static func sample(_ proxy: GeometryProxy) -> FoldSample {
        let origin = proxy.frame(in: .global).origin
        let region = proxy.reservedRegions(kind: .division)
            .first(where: \.isActive)
            .map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
        return FoldSample(region: region, windowSize: proxy.size)
    }
}

@available(iOS 27.1, *)
private extension HingeReading {
    init(_ hinge: DeviceHinge) {
        let status: Status
        switch hinge.status {
        case .closed: status = .closed
        case .fullyOpen: status = .fullyOpen
        default: status = .partiallyOpen
        }
        self.init(status: status, angle: hinge.angle.degrees)
    }
}
#else
/// No fold readings on this SDK or platform: the fold stays `.none`.
private struct FoldInputs: ViewModifier {
    let tracker: FoldTracker

    func body(content: Content) -> some View {
        content
    }
}
#endif

/// `onFoldPiecesChange(_:)`: the view's bounds and place in the window, the
/// window's fold, and the two-pass rule over the pieces they make.
///
/// The view's frame and the window's fold settle on separate clocks: on a
/// rotation the frame changes at once, while the fold settles a confirming
/// pass later at the root. So the reader settles nothing while the root
/// reports a reading still settling (`\.foldIsSettling`), or it would pair
/// its new frame with a crease that no longer exists.
private struct FoldPiecesReader: ViewModifier {
    let action: (FoldPieces) -> Void
    @Environment(\.foldState) private var fold
    @Environment(\.foldIsSettling) private var foldIsSettling
    @State private var frameInWindow: CGRect?
    @State private var settler = FoldSettler<FoldPieces>()

    /// What restarts the confirming pass: a new candidate, or the root
    /// starting or finishing a settle.
    private struct Confirmation: Equatable {
        var candidate: FoldPieces?
        var foldIsSettling: Bool
    }

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                frameInWindow = frame
                pass()
            }
            .onChange(of: fold) { pass() }
            // The first pass once the root's reading settles; the task below
            // is the second.
            .onChange(of: foldIsSettling) { pass() }
            // The confirming pass, a moment after the last change of any
            // input; a newer change restarts it.
            .task(id: Confirmation(candidate: candidate, foldIsSettling: foldIsSettling)) {
                try? await Task.sleep(for: FoldAPI.confirmDelay)
                guard !Task.isCancelled else { return }
                pass()
            }
    }

    private var candidate: FoldPieces? {
        guard let frameInWindow else { return nil }
        return FoldPieces(
            bounds: CGRect(origin: .zero, size: frameInWindow.size),
            fold: fold,
            frameInWindow: frameInWindow
        )
    }

    private func pass() {
        guard !foldIsSettling, let candidate, let settled = settler.pass(candidate) else { return }
        action(settled)
    }
}
