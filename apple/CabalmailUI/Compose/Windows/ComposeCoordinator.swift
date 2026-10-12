import SwiftUI
import CabalmailKit

/// Where an app-level compose request goes: one main window's compose
/// surface, never two.
///
/// A request names the main window it came from: the window whose Reply or
/// New Message was used, or for a mailto: link the window last used. That
/// window's presenter (`ComposeRequestRouter`, registered while the window
/// is signed in) takes the seed. A request that names no window, or one
/// whose window has no presenter (it is signed out, or has gone), goes to
/// the window opened last, and with no presenter at all it waits for the
/// first. A seed its window cannot take yet, because its compose sheet is
/// up (an iPhone, a closed Duo), waits its turn for that window, oldest
/// first. So a mailto: on a cold launch, or while signed out, opens once a
/// window can show it, and two links behind an open sheet both open, one
/// after the other. A seed waiting when the session ends is kept for the
/// next one. No seed waits for a window that cannot come back for it: a
/// seed keeps a window's name only while that window has a presenter.
///
/// Before, a request parked one seed on `AppState` and bumped a tick that
/// every window's router watched: a request that named no window opened a
/// composer in each window, the second one blank, and a second seed
/// replaced one still waiting (#1824).
///
/// `AppState` owns one as `compose`, over the slot registry it also
/// publishes as `composeSlots`. Not `@Observable`: no view observes it.
@MainActor
public final class ComposeCoordinator {
    /// One main window's compose surface.
    @MainActor
    final class Presenter {
        let window: UUID?
        private let present: @MainActor (Draft) -> Bool

        /// - Parameters:
        ///   - window: the main window (`commandWindowID`); nil outside one
        ///     (a test, a preview), which takes only requests naming none.
        ///   - present: shows the seed, or returns false while it cannot.
        init(window: UUID?, present: @escaping @MainActor (Draft) -> Bool) {
            self.window = window
            self.present = present
        }

        fileprivate func take(_ seed: Draft) -> Bool {
            present(seed)
        }
    }

    /// A seed waiting for a presenter, and the window whose presenter it
    /// waits for, which has one; nil for whichever presenter is there, or
    /// registers first.
    private struct Waiting {
        var window: UUID?
        let seed: Draft
    }

    let slots: ComposeSlotRegistry

    /// In the order they registered: the last is the window opened last.
    private var presenters: [Presenter] = []
    /// In the order they arrived.
    private var waiting: [Waiting] = []
    /// Forwarded attachments by draft, until the composer takes them.
    private var attachments: [UUID: [Attachment]] = [:]
    /// The main window each open compose window came from.
    private var origins: [ComposeSlot: UUID] = [:]
    private var isDelivering = false
    private var deliverAgain = false

    init(slots: ComposeSlotRegistry) {
        self.slots = slots
    }

    // MARK: Requests

    /// Opens a composer on `seed` in `window`'s compose surface, or parks
    /// the seed until that window can show it. `attachments` (a forward's)
    /// wait for the composer under the draft's identity
    /// (`takeAttachments(for:)`); opening the same draft again replaces
    /// them.
    func open(seed: Draft, attachments: [Attachment] = [], from window: UUID?) {
        if !attachments.isEmpty { self.attachments[seed.id] = attachments }
        waiting.append(Waiting(window: window.flatMap { hasPresenter(for: $0) ? $0 : nil }, seed: seed))
        deliver()
    }

    /// The seeds waiting for `window`'s presenter, oldest first; with nil,
    /// those waiting for whichever presenter is there or registers first.
    func seedsWaiting(for window: UUID?) -> [Draft] {
        waiting.filter { $0.window == window }.map(\.seed)
    }

    /// The attachments `open` was given for this draft, once. A compose
    /// scene the system restored finds none, and composes without them.
    func takeAttachments(for draftID: UUID) -> [Attachment] {
        attachments.removeValue(forKey: draftID) ?? []
    }

    // MARK: Presenters

    /// A main window's compose surface is ready. It takes what was waiting
    /// for it, and for no window in particular, oldest first.
    func register(_ presenter: Presenter) {
        presenters.append(presenter)
        deliver()
    }

    /// A main window's compose surface has gone: its window signed out, or
    /// closed. What waited behind its sheet waits for whichever surface is
    /// there or comes next: the window's own when it signs back in, or
    /// another's if the window does not come back.
    func unregister(_ presenter: Presenter) {
        presenters.removeAll { $0 === presenter }
        guard let window = presenter.window, !hasPresenter(for: window) else { return }
        for index in waiting.indices where waiting[index].window == window {
            waiting[index].window = nil
        }
        deliver()
    }

    /// A presenter that refused a seed can take one now: its sheet closed.
    func presenterIsFree() {
        deliver()
    }

    // MARK: Compose windows

    /// The slot for a compose window opened on `seed` from `window`, which
    /// closing it returns to (`origin(of:)`).
    func slot(for seed: Draft, from window: UUID?) -> ComposeSlot {
        let slot = slots.acquire(seed: seed)
        origins[slot] = window
        return slot
    }

    /// The main window the compose window holding `slot` came from. Nil for
    /// one the Mac's menus opened, or with no slot: a window the system
    /// restored, or spawned for a mailto: link.
    func origin(of slot: ComposeSlot?) -> UUID? {
        slot.flatMap { origins[$0] }
    }

    /// The Mac's File ▸ New Message and its menu-bar item: a compose scene
    /// opened directly, so both work with every main window closed (#1162).
    /// No presenter is asked, and it has no window to return to.
    public func openNewWindow(seed: Draft, using openWindow: OpenWindowAction) {
        openNewWindow(seed: seed) { openWindow(id: composeWindowID, value: $0) }
    }

    func openNewWindow(seed: Draft, open: (ComposeSlot) -> Void) {
        open(slot(for: seed, from: nil))
    }

    // MARK: Delivery

    private func hasPresenter(for window: UUID) -> Bool {
        presenters.contains { $0.window == window }
    }

    /// The presenter a seed waiting for `window` goes to: that window's,
    /// else, for a seed naming none, the one registered last.
    private func presenter(for window: UUID?) -> Presenter? {
        guard let window else { return presenters.last }
        return presenters.last { $0.window == window }
    }

    /// Hands each waiting seed to its presenter, oldest first, until a pass
    /// is asked for nothing more. A presenter showing a seed can open
    /// another composer, and one being offered a seed can bring another
    /// window's surface up: a request made during a pass is answered by one
    /// more pass after it, never from inside it.
    private func deliver() {
        guard !isDelivering else { return deliverAgain = true }
        isDelivering = true
        defer { isDelivering = false }
        repeat {
            deliverAgain = false
            offerWaitingSeeds()
        } while deliverAgain
    }

    /// One pass. A seed is taken off the queue before it is offered, so it
    /// cannot be handed over twice. A presenter that refuses keeps the
    /// seed, now its own, at its place in the queue, and is offered nothing
    /// behind it this pass, so no request is shown ahead of an older one
    /// for the same window.
    private func offerWaitingSeeds() {
        var busy: [Presenter] = []
        var index = 0
        while index < waiting.count {
            let next = waiting[index]
            guard let presenter = presenter(for: next.window), !busy.contains(where: { $0 === presenter }) else {
                index += 1
                continue
            }
            waiting.remove(at: index)
            if presenter.take(next.seed) { continue }
            busy.append(presenter)
            waiting.insert(Waiting(window: presenter.window ?? next.window, seed: next.seed), at: index)
            index += 1
        }
    }
}
