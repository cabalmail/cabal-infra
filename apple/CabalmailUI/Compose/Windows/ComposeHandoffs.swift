import Foundation
import Observation

/// Drafts on their way from an iOS compose sheet to a window of their own
/// ("Open in New Window", `ComposeWindowMove`), keyed by draft ID.
///
/// The sheet expects a window for its draft at the tap, asks for the window,
/// and sends its composer's state afterwards, once it has read it
/// (`fulfil`). The window waits for that state before it builds a composer
/// (`awaitsSnapshot`), then claims the draft once it has it in its own editor
/// and is in front. The sheet lets its draft go only on that claim.
/// `openWindow` reports no failure on iOS, so a window that never comes, or
/// comes too late, reads as no claim before the deadline, which runs from the
/// tap: the sheet withdraws the offer and carries on as it was. A withdrawn
/// offer stays withdrawn, so neither a window that turns up after the sheet
/// has taken its draft back nor a snapshot read after the deadline can take
/// it too.
///
/// Everything runs on the main actor, so an offer is claimed or withdrawn
/// once, by whichever comes first. Observable, so a window waiting for its
/// draft builds its composer as soon as the snapshot comes, or the offer
/// ends without one.
///
/// `ComposeCoordinator` owns one as `handoffs`.
@Observable
@MainActor
final class ComposeHandoffs {
    enum Outcome: Equatable {
        /// A window has the draft; the sheet lets it go.
        case claimed
        /// No window took it in time, the one that came could not hold it,
        /// or the sheet could not read it; the sheet keeps it.
        case refused
    }

    /// Every hand-off expected this process, by draft ID. A resolved one is
    /// kept, without its snapshot, so a window that comes for it late finds
    /// it gone rather than nothing at all.
    private var offers: [UUID: ComposeHandoffOffer] = [:]
    private let sleep: @MainActor (Duration) async -> Void

    /// - Parameter sleep: waits out a deadline; a test's own, so it need not.
    init(sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// The sheet's side, at the tap, before it asks for the window: a window
    /// is about to open for `draftID`, and the draft follows it. The deadline
    /// runs from now. At it the offer is withdrawn, whether or not its
    /// snapshot has come: the sheet keeps its draft, and a claim or a
    /// snapshot after that fails.
    func expect(_ draftID: UUID, within deadline: Duration) {
        let offer = ComposeHandoffOffer(draftID: draftID, sleep: sleep)
        offers[draftID] = offer
        offer.arm(deadline)
    }

    /// The sheet's composer, read, for the window waiting on its draft.
    /// False when the offer ended first: the deadline passed while the sheet
    /// was still reading it.
    @discardableResult
    func fulfil(_ snapshot: ComposeSnapshot) -> Bool {
        offers[snapshot.draftID]?.fulfil(snapshot) ?? false
    }

    /// The sheet keeps `draftID`: it could not read the draft, or the move
    /// ended without a claim. A window waiting for the snapshot then closes,
    /// once it is in front, without composing the draft.
    func withdraw(_ draftID: UUID) {
        offers[draftID]?.withdraw()
    }

    /// Whether a window opened for `draftID` has its draft still to come:
    /// the sheet has asked for the window and not yet sent the snapshot, nor
    /// taken the draft back. Until then the window builds no composer, which
    /// would start from nothing.
    func awaitsSnapshot(for draftID: UUID) -> Bool {
        offers[draftID]?.state == .expected
    }

    /// A claim on the hand-off for a compose window opened on `draftID`, a
    /// new one for each composer that asks, or nil when none was ever
    /// expected. A resolved one comes back too, with no snapshot, and cannot
    /// be claimed: a window that comes late must close rather than compose
    /// its draft from nothing, which would empty the local copy on its first
    /// autosave.
    func pending(for draftID: UUID) -> ComposeHandoffClaim? {
        offers[draftID].map(ComposeHandoffClaim.init)
    }

    /// Waits for a window to claim `draftID`'s hand-off, or for the hand-off
    /// to end without a claim: declined by the window, withdrawn by the
    /// sheet, or past its deadline.
    func outcome(for draftID: UUID) async -> Outcome {
        guard let offer = offers[draftID] else { return .refused }
        return await offer.outcome()
    }
}

/// One composer's claim on a draft's hand-off: the snapshot it starts from,
/// and the claim that takes the draft from the sheet.
///
/// Each composer built for the draft holds its own. SwiftUI keeps a closed
/// compose window mounted (#1084), and one rebuilt for the recycled slot
/// builds a composer for the draft too, behind the window opened for it and
/// on the same slot. Only a composer whose own window is in front claims;
/// one behind, or one another composer beat to it, touches neither the
/// hand-off nor the slot.
@Observable
@MainActor
final class ComposeHandoffClaim {
    private let offer: ComposeHandoffOffer
    /// Whether this composer took the draft. Until it has, it sends, saves
    /// and closes nothing, and its form is frozen
    /// (`ComposeViewModel.isAwaitingClaim`).
    private(set) var hasClaimed = false
    /// Whether this composer's window is in front (`scenePhase == .active`),
    /// which its claim waits for, so the draft never lands in a window
    /// nobody can see.
    @ObservationIgnored var sceneIsActive = false {
        didSet { if sceneIsActive { cameForward() } }
    }
    /// The close of a composer whose window was behind when the sheet took
    /// the draft back, run once its window is in front.
    @ObservationIgnored private var closeInFront: (@MainActor () -> Void)?

    fileprivate init(_ offer: ComposeHandoffOffer) {
        self.offer = offer
    }

    var draftID: UUID { offer.draftID }
    /// What the composer starts from; nil until the sheet has sent it, and
    /// once the hand-off has been claimed or withdrawn.
    var snapshot: ComposeSnapshot? { offer.snapshot }

    /// Starts `model`, the composer this claim was made for: the sheet's
    /// rich text into its editor, then, once its window is in front, the
    /// claim, and only then its autosaves and its own address load. Until
    /// the claim the sheet may still take the draft back, so the composer
    /// writes nothing.
    ///
    /// In front, a composer that cannot hold the draft declines it. One the
    /// sheet has the draft back from closes through its own close, which
    /// frees its slot and returns to the main window, saving nothing: at
    /// once if it is in front, else when it comes in front, so a window that
    /// was behind is not left frozen with nothing in it. A composer another
    /// one beat to the draft does nothing: its close would free the slot the
    /// two share and bring the main window over the one holding the draft.
    func takeOver(_ model: ComposeViewModel) async {
        offer.windowArrived(within: ComposeWindowMove.takeOverDeadline)
        let restored = await restore(into: model)
        await inFrontOrEnded()
        if restored, await claim() {
            model.autosave.start(for: model)
            return await model.refreshAddresses()
        }
        if sceneIsActive { decline() }
        guard offer.state == .withdrawn else { return }
        closeInFront = model.onClose
        closeIfInFront()
    }

    /// Puts the sheet's rich text into `model`'s editor and proves the
    /// bridge answers with it there. False when there is nothing to restore
    /// or the bridge failed.
    ///
    /// The quoted images in the markup were blocked when the sheet was
    /// seeded, so nothing is blocked again here. The mirror flag is put back
    /// after the load, from the snapshot, whatever the editor reported while
    /// it loaded.
    func restore(into model: ComposeViewModel) async -> Bool {
        guard let snapshot else { return false }
        await model.editorController.setHTML(snapshot.richHTML ?? "")
        model.richMirrorsMarkdown = snapshot.richMirrorsMarkdown
        return (try? await model.editorController.checked.getHTML()) != nil
    }

    /// Takes the draft from the sheet, once this composer's window is in
    /// front. False when the hand-off ended first: the sheet took the draft
    /// back, or another composer claimed it.
    func claim() async -> Bool {
        await inFrontOrEnded()
        guard sceneIsActive, offer.claim() else { return false }
        hasClaimed = true
        return true
    }

    /// The composer could not hold the draft: the sheet keeps it now rather
    /// than at its deadline.
    func decline() {
        offer.withdraw()
    }

    private func inFrontOrEnded() async {
        while !sceneIsActive, offer.isOpen {
            await offer.nextChange()
        }
    }

    private func cameForward() {
        offer.wake()
        closeIfInFront()
    }

    private func closeIfInFront() {
        guard sceneIsActive, let close = closeInFront else { return }
        closeInFront = nil
        close()
    }
}

/// One draft's hand-off, shared by every composer's claim on it: the
/// snapshot once the sheet has sent it, whether it is still on offer, and
/// the sheet's wait for how it ended.
@Observable
@MainActor
private final class ComposeHandoffOffer {
    enum State {
        /// The window is asked for; the sheet has yet to send the snapshot.
        case expected
        /// The snapshot is in, for the window to claim.
        case offered
        case claimed
        case withdrawn
    }

    let draftID: UUID
    private(set) var snapshot: ComposeSnapshot?
    private(set) var state = State.expected
    /// Withdraws the offer when the sheet's deadline passes; cancelled once
    /// the hand-off has ended.
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private let sleep: @MainActor (Duration) async -> Void
    /// Whether a window has started taking the draft over, which gave the
    /// hand-off its second, longer deadline.
    @ObservationIgnored private var windowHasArrived = false
    /// Composers waiting for their window to come in front. Each looks again
    /// whenever any composer's window does, and when the hand-off ends.
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var outcomeWaiters: [CheckedContinuation<ComposeHandoffs.Outcome, Never>] = []

    init(draftID: UUID, sleep: @escaping @MainActor (Duration) async -> Void) {
        self.draftID = draftID
        self.sleep = sleep
    }

    /// Withdraws the offer once `deadline` has passed, unless it has ended
    /// first or the deadline is armed again.
    func arm(_ deadline: Duration) {
        self.deadline?.cancel()
        self.deadline = Task { @MainActor [sleep, weak self] in
            await sleep(deadline)
            if !Task.isCancelled { self?.withdraw() }
        }
    }

    /// A window has started taking the draft over, its composer built from
    /// the snapshot: the deadline starts again, at `deadline`, once. The
    /// window still has to come in front and boot its editor, and a new
    /// WebKit content process can take a while to answer (measured: about
    /// ten seconds on the iPadOS 27.0 simulator, where a reduction's took
    /// under three), so the first deadline only bounds how long the sheet
    /// waits for a window to turn up at all.
    func windowArrived(within deadline: Duration) {
        guard isOpen, !windowHasArrived else { return }
        windowHasArrived = true
        arm(deadline)
    }

    /// Until it has been claimed or withdrawn, with its snapshot or not yet.
    var isOpen: Bool { state == .expected || state == .offered }

    /// False once the snapshot is in, or the hand-off has ended.
    func fulfil(_ snapshot: ComposeSnapshot) -> Bool {
        guard state == .expected else { return false }
        self.snapshot = snapshot
        state = .offered
        wake()
        return true
    }

    /// False until the snapshot is in, and once the hand-off has been
    /// claimed or withdrawn.
    func claim() -> Bool {
        guard state == .offered else { return false }
        resolve(.claimed)
        return true
    }

    func withdraw() {
        guard isOpen else { return }
        resolve(.withdrawn)
    }

    /// The sheet's side: how the hand-off ended, once it has.
    func outcome() async -> ComposeHandoffs.Outcome {
        switch state {
        case .claimed: return .claimed
        case .withdrawn: return .refused
        case .expected, .offered: return await withCheckedContinuation { outcomeWaiters.append($0) }
        }
    }

    /// Parks a composer until a window comes in front or the hand-off ends.
    func nextChange() async {
        guard isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func wake() {
        waiters.forEach { $0.resume() }
        waiters = []
    }

    private func resolve(_ end: State) {
        state = end
        snapshot = nil
        deadline?.cancel()
        deadline = nil
        let outcome: ComposeHandoffs.Outcome = end == .claimed ? .claimed : .refused
        outcomeWaiters.forEach { $0.resume(returning: outcome) }
        outcomeWaiters = []
        wake()
    }
}
