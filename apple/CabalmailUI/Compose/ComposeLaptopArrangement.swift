import SwiftUI

/// One compose surface's laptop pose: what the sheet reads of the fold, the
/// software keyboard and its own scroll, and what follows from them through
/// `ComposeLaptopPolicy`. `ComposeView` holds one; `readsComposeLaptop`
/// feeds it and puts it in the environment for `ComposerBody`.
///
/// Laptop pose is a horizontal fold whose band crosses the sheet: the
/// window's fold, and the sheet's own bounds split into a top and a bottom
/// piece, read with the keyboard ignored so typing never ends it.
///
/// The body's height comes from where the body and the From header sat at
/// rest (`ComposeLaptopPolicy.RestMetrics`), sampled only at the form's
/// top, idle, with the keyboard down, and published once the frames have
/// held for `confirmDelay`, so the order the callbacks arrive in doesn't
/// matter. The geometry and scroll inputs are not observed: a scroll frame
/// re-renders nothing.
@MainActor @Observable
final class ComposeLaptopArrangement {
    /// The fold's band in window coordinates while the sheet is in laptop
    /// pose, else nil.
    private(set) var crease: CGRect?
    /// Where the software keyboard ends up, or nil.
    private(set) var keyboard: CGRect?
    /// A field or an editor has focus. The keyboard counts only then: a
    /// posture change can take the focus and the keyboard away without a
    /// hide notification, and the last frame, from the other orientation,
    /// would keep the bars at the top (measured).
    private(set) var isEditing = false
    /// The body and From header's places at rest, once sampled.
    private(set) var rest: ComposeLaptopPolicy.RestMetrics?
    /// How many times Edit Message has been pressed: `ComposerBody` puts
    /// the caret back on each.
    private(set) var editRequests = 0

    @ObservationIgnored private var fieldEditing = false
    @ObservationIgnored private var markdownEditing = false
    @ObservationIgnored private var fold: FoldState = .none
    @ObservationIgnored private var stacked = false
    @ObservationIgnored private var bodyFrameInWindow: CGRect?
    @ObservationIgnored private var fieldsTop: CGFloat?
    @ObservationIgnored private var scrolledFromRest: CGFloat = 0
    @ObservationIgnored private(set) var isScrolling = false
    @ObservationIgnored private var lastUserScroll: TimeInterval?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let confirmDelay: Duration

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        confirmDelay: Duration = FoldAPI.confirmDelay
    ) {
        self.now = now
        self.confirmDelay = confirmDelay
    }

    var isLaptop: Bool { crease != nil }
    var host: ComposeLaptopPolicy.BarHost {
        ComposeLaptopPolicy.barHost(crease: crease, keyboard: isEditing ? keyboard : nil)
    }
    var barsBelowFold: Bool { host == .laptopBottom }
    var sections: [ComposeFormSection] { ComposeFormSection.order(inLaptop: isLaptop) }
    var bodyFrame: ComposeLaptopPolicy.BodyFrame { ComposeLaptopPolicy.bodyFrame(crease: crease, rest: rest) }
    var toastFloor: CGFloat? { ComposeLaptopPolicy.toastFloor(host: host, crease: crease) }
    /// Seconds since the user last scrolled the form themselves.
    var secondsSinceUserScroll: TimeInterval? { lastUserScroll.map { now() - $0 } }

    // MARK: Inputs

    func foldChanged(_ fold: FoldState) {
        self.fold = fold
        updateCrease()
    }

    func piecesChanged(_ pieces: FoldPieces) {
        if case .stacked = pieces { stacked = true } else { stacked = false }
        updateCrease()
    }

    func keyboardChanged(_ keyboard: CGRect?) {
        if self.keyboard != keyboard { self.keyboard = keyboard }
        sample()
    }

    /// A recipient field, Subject or the rich editor has focus.
    func fieldsEditing(_ editing: Bool) {
        fieldEditing = editing
        updateEditing()
    }

    /// The Markdown editor has focus.
    func markdownEditing(_ editing: Bool) {
        markdownEditing = editing
        updateEditing()
    }

    func bodyMoved(_ frame: CGRect) {
        bodyFrameInWindow = frame
        sample()
    }

    func fieldsMoved(top: CGFloat) {
        fieldsTop = top
        sample()
    }

    /// How far the form is scrolled from its top (offset plus top inset).
    func scrolled(fromRest offset: CGFloat) {
        scrolledFromRest = offset
        sample()
    }

    func scrollPhase(_ phase: ScrollPhase) {
        isScrolling = phase != .idle
        if phase == .tracking || phase == .interacting || phase == .decelerating {
            lastUserScroll = now()
        }
        sample()
    }

    func requestEdit() {
        editRequests += 1
    }

    // MARK: Derivation

    private func updateEditing() {
        let next = fieldEditing || markdownEditing
        guard next != isEditing else { return }
        isEditing = next
        sample()
    }

    private func updateCrease() {
        let next: CGRect? = if case .horizontal(let crease) = fold, stacked { crease } else { nil }
        guard next != crease else { return }
        crease = next
        if next == nil { rest = nil }
        sample()
    }

    /// Publishes the rest metrics once the frames have held for
    /// `confirmDelay`, if they are a rest sample.
    private func sample() {
        sampling?.cancel()
        guard isLaptop else { return }
        sampling = Task { [weak self, confirmDelay] in
            try? await Task.sleep(for: confirmDelay)
            guard !Task.isCancelled, let self else { return }
            self.publishRest()
        }
    }

    private func publishRest() {
        guard ComposeLaptopPolicy.samplesRest(host: host, isScrolling: isScrolling, scrolledFromRest: scrolledFromRest),
              let bodyFrameInWindow, let fieldsTop else { return }
        let next = ComposeLaptopPolicy.restMetrics(bodyFrame: bodyFrameInWindow, fieldsTop: fieldsTop)
        if ComposeLaptopPolicy.restMoved(from: rest, to: next) { rest = next }
    }
}

extension EnvironmentValues {
    /// The compose surface's laptop arrangement, for `ComposerBody`; nil
    /// outside compose, where every laptop value is today's.
    @Entry var composeLaptop: ComposeLaptopArrangement?
}
