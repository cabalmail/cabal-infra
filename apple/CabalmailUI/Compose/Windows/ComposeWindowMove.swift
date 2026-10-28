import SwiftUI
import WebKit
import CabalmailKit

/// "Open in New Window" from an iOS compose sheet: moves the composer to a
/// compose window of its own, window first and sheet last.
///
/// The window is asked for at the tap, in the button's own turn, and the
/// draft follows it. Asked for only once the sheet had flushed and read its
/// draft, several awaits after the tap, the window opened on an iPad
/// simulator but never came in front, so it never claimed the draft and the
/// move was refused; a request made that late no longer runs in the tap's
/// turn, which is the likeliest reason.
///
/// The sheet hands over a snapshot of its composer (`ComposeSnapshot`)
/// rather than the composer itself: one `WKWebView` cannot sit in two
/// scenes, and a snapshot leaves the sheet's model untouched until the
/// window has claimed the draft (`ComposeHandoffs`). The window builds its
/// composer only once the snapshot has come. Until the claim the sheet is
/// frozen and its autosaves paused; once claimed, the sheet goes and the
/// draft carries on in the window under the same ID and server copy. If no
/// window claims it in time (`openWindow` reports no failure on iOS), the
/// sheet carries on as it was, says the window didn't open, and stops
/// offering the action, and a window that did open closes once it is in
/// front, saving nothing.
///
/// Held by the window's `ComposeRequestRouter` and reset for each sheet it
/// presents.
@Observable
@MainActor
final class ComposeWindowMove {
    enum Phase: Equatable {
        case idle
        /// Frozen while the window opens, and while the sheet leaves once
        /// it has.
        case moving
        /// No window took the draft: the sheet stays, and offers no second
        /// move.
        case refused
    }

    /// What a move reaches outside the sheet: the coordinator and its
    /// hand-off table, the main window the sheet is over, and the router's
    /// ways to open a window and close its sheet.
    struct Route {
        let compose: ComposeCoordinator
        let origin: UUID?
        let navigator: SceneNavigator
        let openWindow: @MainActor (ComposeSlot) -> Void
        let closeSheet: @MainActor () -> Void
    }

    /// How long the sheet waits, from the tap, for a window to start taking
    /// the draft over. In that time the sheet flushes and reads its draft,
    /// behind any save in flight, and the window builds its composer from
    /// it. A window that never turns up reads as a refusal, and the sheet
    /// keeps the draft. Tests pass their own wait to
    /// `ComposeHandoffs(sleep:)`.
    static let deadline = Duration.seconds(10)

    /// How long the sheet then gives the window that has turned up to come
    /// in front, boot its editor and claim the draft
    /// (`ComposeHandoffOffer.windowArrived(within:)`); the moved composer's
    /// editor waits as long for its bridge (`editorReadyTimeout`).
    static let takeOverDeadline = Duration.seconds(30)

    /// The moved composer's editor-bridge timeout, in seconds: the take-over
    /// deadline, rather than the ten seconds a composer the user opened gets.
    static let editorReadyTimeout: TimeInterval = 30

    static let refusedMessage = "The new window didn't open. Your message is still here."

    private(set) var phase = Phase.idle

    var isMoving: Bool { phase == .moving }
    var refused: Bool { phase == .refused }

    /// A new sheet: offer the action again.
    func reset() {
        phase = .idle
    }

    /// Moves `model`'s draft to a new compose window. Called from the
    /// button's action: everything up to the window request runs in the
    /// tap's own turn, before anything awaits, and the rest in the task this
    /// returns. Nil, with nothing done, when the draft may not move.
    ///
    /// At the tap the model refuses Send, Cancel and Discard, the sheet takes
    /// a slot for the window, recording the main window it is over, expects
    /// a hand-off for the draft, whose deadline starts then, asks for the
    /// window, and pauses its autosave loops. Then the local copy is flushed
    /// once more for the window to keep writing, and the sheet reads its
    /// composer and sends it to the window inside the server draft queue's
    /// close, behind any save already in flight, so the snapshot carries the
    /// copy that save landed and no later tick can replace it.
    ///
    /// Claimed: the sheet closes and the window's lock releases at once, so
    /// a deep link that waited for the sheet opens even if the system holds
    /// back the sheet's dismissal in a scene it has moved behind the new
    /// window. Nothing a closing composer does runs: the draft is not
    /// cancelled, discarded or removed, and no event is posted, because it
    /// is still being written. Refused, or the snapshot could not be read:
    /// the hand-off is withdrawn, so a window waiting for the draft closes
    /// instead; the queue reopens, the loops restart, and nothing else of the
    /// composer's start runs again.
    @discardableResult
    func move(_ model: ComposeViewModel, along route: Route) -> Task<Void, Never>? {
        guard phase == .idle, model.mayHandOff else { return nil }
        phase = .moving
        model.isMovingToWindow = true
        _ = model.editorController.webView.resignFirstResponder()
        // Records the window the draft came from, which closing the new
        // window returns to.
        let slot = route.compose.slot(for: Draft(id: model.draftId), from: route.origin)
        route.compose.handoffs.expect(model.draftId, within: Self.deadline)
        route.openWindow(slot)
        model.stop()
        return Task { await handOver(model, along: route) }
    }

    /// The rest of the move, after the tap: the draft follows the window.
    private func handOver(_ model: ComposeViewModel, along route: Route) async {
        let handoffs = route.compose.handoffs
        await model.persistCurrentDraft()
        do {
            try await model.serverDraftQueue.close(runningThrowing: {
                let snapshot = try await ComposeSnapshot.capture(from: model)
                handoffs.fulfil(snapshot)
                guard await handoffs.outcome(for: model.draftId) == .claimed else { throw Refused() }
            })
        } catch {
            handoffs.withdraw(model.draftId)
            model.isMovingToWindow = false
            model.autosave.start(for: model)
            model.errorMessage = Self.refusedMessage
            phase = .refused
            return
        }
        route.closeSheet()
        route.navigator.composeClosed()
    }

    private struct Refused: Error {}
}

extension View {
    /// Freezes a composer while its draft moves between a sheet and a
    /// window: the sheet while it hands the draft over (`isMoving`), the
    /// window's placeholder until the draft has come, and the window's
    /// composer until it has claimed it (`ComposeViewModel.isAwaitingClaim`).
    /// No tap or keystroke reaches it, and it says why.
    func frozen(while isFrozen: Bool) -> some View {
        disabled(isFrozen)
            .allowsHitTesting(!isFrozen)
            .overlay {
                if isFrozen {
                    ProgressView("Opening in a new window…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
    }
}
