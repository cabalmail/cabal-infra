import SwiftUI
import CabalmailKit

/// The row at the top of a virtualized message list. Every row is one
/// height (`MessageListView.rowHeight`), so the content scrolled past the
/// top inset, over that height, is the index.
enum ListPlaceGeometry {
    static func topRow(contentOffset: CGFloat, topInset: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0, rowHeight.isFinite, contentOffset.isFinite, topInset.isFinite else { return 0 }
        // Half a point of slack: a restore's own landing can read up to a
        // pixel under the row boundary once a scaled row height is rounded
        // to pixels.
        let scrolled = contentOffset + topInset + 0.5
        return scrolled > 0 ? Int((scrolled / rowHeight).rounded(.down)) : 0
    }
}

/// One message list's part in keeping its window's list place: it records
/// the list's top row as the list scrolls, and once the list has appeared
/// and loaded it scrolls to the place its window parked for it or kept
/// (`FolderListHold`).
///
/// One per `MessageListView` (`@State`), so it survives a reader pushed over
/// the list and popped, and a list that comes back lands nothing again. The
/// model stays the view's: nothing here holds one.
///
/// It records and lands only on a folder list on the All pill in the default
/// sort, whose rows are index-addressed, and records only while the list is
/// on screen with no error row above its rows, under the claim the list took
/// from its window. A layout swap or a newer list voids that claim, so a
/// list from a tree being torn down can neither record nor take the anchor
/// parked for its successor.
@Observable
@MainActor
final class ListPlaceTracker {
    /// A row for the modifier to scroll to, by slot at the moment it scrolls.
    struct ScrollRequest: Equatable {
        let row: Int
        fileprivate let tick: Int

        /// What to hand the scroll view, read as it scrolls: a row a full
        /// swipe replaced has a new identity
        /// (`MessageListViewModel+RowReplacement`).
        @MainActor
        func slot(in model: MessageListViewModel) -> MessageListSlot {
            model.rowSlot(at: row)
        }
    }

    /// What the loads a landing waits on look like now.
    struct LoadState: Equatable {
        let slots: Int
        let windowStart: Int
        let loaded: Int
        let isLoading: Bool
        let countKnown: Bool

        @MainActor
        init(_ model: MessageListViewModel) {
            slots = model.slotCount
            windowStart = Int(model.window?.windowStart ?? 0)
            loaded = model.envelopes.count
            isLoading = model.isLoading
            countKnown = ListPlaceTracker.countKnown(model)
        }
    }

    /// A landing still settling.
    private struct Pending {
        let anchor: ListAnchor
        /// The row the landing scrolled to as a guess; nil while it waits
        /// for the folder's count.
        let guess: Int?
        /// Whether the list has moved on its own since: the user's scroll
        /// wins, so the landing no longer corrects itself.
        var listMoved = false
    }

    /// The one observed property: the modifier scrolls on its change.
    private(set) var scrollRequest: ScrollRequest?

    @ObservationIgnored private weak var navigator: SceneNavigator?
    @ObservationIgnored private var claim: FolderListHold.Claim?
    @ObservationIgnored private var didLand = false
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var requests = 0
    /// The row the last request asked for, until the list moves: a request
    /// made while a reader covers the list is asked again when the list
    /// comes back. While it is set, the list's next move is the request's
    /// own and is not recorded: it can be clamped (the last rows of a folder
    /// cannot reach the top), and recording where it stopped would shift the
    /// place a little on every fold.
    @ObservationIgnored private var requested: Int?
    /// The list's top row as last reported.
    @ObservationIgnored private var top = 0

    // MARK: The view's calls

    /// The list's scroll view came on screen: take the window's claim the
    /// first time, or again if a back-out voided it under a list that
    /// stayed alive.
    func appeared(_ model: MessageListViewModel, in navigator: SceneNavigator?) {
        isOnScreen = true
        takeClaimIfNeeded(model, in: navigator)
        if let requested { scroll(to: requested) }
    }

    func disappeared() {
        isOnScreen = false
    }

    /// The landing: once per list, after it has appeared and loaded. Takes
    /// the anchor parked for the list's folder, or the window's place when
    /// it is that folder's, and scrolls there. A list that does not land
    /// (a pill, a sort) still takes the parked anchor, and leaves the
    /// window's place as it is.
    func land(model: MessageListViewModel, in navigator: SceneNavigator?) {
        guard !didLand else { return }
        didLand = true
        takeClaimIfNeeded(model, in: navigator)
        guard let claim, let navigator,
              let anchor = navigator.listHold.takeAnchor(under: claim, from: navigator.restores),
              Self.lands(model)
        else { return }
        aim(at: anchor, model: model)
    }

    /// The list scrolled so `top` is its top row.
    func scrolled(toRow top: Int, model: MessageListViewModel) {
        guard isOnScreen else { return }
        self.top = top
        // The move a request of this list's own made.
        guard requested == nil else { return requested = nil }
        guard didLand, Self.records(model), let claim else { return }
        guard let pending else {
            return record(Self.anchor(atRow: top, of: model, folderPath: claim.folderPath))
        }
        guard pending.guess != nil else { return }
        // A guess never overwrites: the parked identity stays until its row
        // arrives, and only the index follows the list.
        self.pending?.listMoved = true
        record(pending.anchor.moved(to: top))
    }

    /// The user began to scroll the list. What it does next is theirs, not
    /// a request's, and wins over a landing still settling.
    func userScrolled() {
        requested = nil
        pending?.listMoved = true
    }

    /// The loaded rows, the count or the loading changed: finishes a
    /// landing that waited on them, and keeps the place's identity true to
    /// the row now at its index.
    func loadsChanged(model: MessageListViewModel) {
        guard let claim, let navigator, navigator.listHold.holds(claim), Self.lands(model) else { return }
        guard let pending else { return refreshIdentity(model, claim: claim) }
        if let guess = pending.guess {
            settle(pending.anchor, guessedAt: guess, model: model)
        } else if Self.countKnown(model) || pending.anchor.index < model.slotCount {
            self.pending = nil
            aim(at: pending.anchor, model: model)
        }
    }

    // MARK: Landing

    private func aim(at anchor: ListAnchor, model: MessageListViewModel) {
        let start = Int(model.window?.windowStart ?? 0)
        switch anchor.landing(
            rows: model.envelopes, windowStart: start, slotCount: model.slotCount, countKnown: Self.countKnown(model)
        ) {
        case .found(let row):
            record(anchor.moved(to: row))
            scroll(to: row)
        case .position(let row):
            record(Self.anchor(atRow: row, of: model, folderPath: anchor.folderPath))
            scroll(to: row)
        case .guess(let row):
            pending = Pending(anchor: anchor, guess: row)
            record(anchor.moved(to: row))
            // Before the scroll, as Home and End do: the rows swept through
            // would otherwise claim the load for somewhere else.
            model.window?.ensureLoaded(around: row)
            scroll(to: row)
        case .wait:
            pending = Pending(anchor: anchor, guess: nil)
            record(anchor)
        case .drop:
            record(nil)
        }
    }

    /// A guessed landing meets new rows: the message's row arrived (correct
    /// once), or the rows around the guess loaded without it (it is gone),
    /// or neither yet (ask for them again, in case a refresh in flight
    /// turned the first request away).
    private func settle(_ anchor: ListAnchor, guessedAt guess: Int, model: MessageListViewModel) {
        let start = Int(model.window?.windowStart ?? 0)
        if pending?.listMoved == true, let claim {
            // The user scrolled meanwhile, and that wins: no correction, and
            // the place is the row the list is on.
            pending = nil
            record(Self.anchor(atRow: top, of: model, folderPath: claim.folderPath))
        } else if let row = anchor.row(in: model.envelopes, windowStart: start) {
            pending = nil
            record(anchor.moved(to: row))
            if row != guess { scroll(to: row) }
        } else if model.envelope(inSlot: guess) != nil {
            pending = nil
            record(Self.anchor(atRow: guess, of: model, folderPath: anchor.folderPath))
        } else if !model.isLoading {
            model.window?.ensureLoaded(around: guess)
        }
    }

    /// With nothing pending, the row at the place's index may have loaded
    /// since it was recorded (a fast scroll onto placeholders), or may be
    /// another message now (mail arrived above it): the place names the
    /// message that is there.
    private func refreshIdentity(_ model: MessageListViewModel, claim: FolderListHold.Claim) {
        guard didLand, isOnScreen, Self.records(model),
              let place = navigator?.listHold.place, place.folderPath == claim.folderPath,
              let envelope = model.envelope(inSlot: place.index), !place.names(envelope)
        else { return }
        record(Self.anchor(atRow: place.index, of: model, folderPath: claim.folderPath))
    }

    // MARK: Plumbing

    private func takeClaimIfNeeded(_ model: MessageListViewModel, in navigator: SceneNavigator?) {
        guard let navigator, let folderPath = model.folder?.path else { return }
        if let claim, navigator.listHold.holds(claim) { return }
        self.navigator = navigator
        claim = navigator.listHold.claim(folderPath)
    }

    /// Records the place with the window and, when it changed, with the
    /// resume session, which keeps it only from the window last used.
    private func record(_ anchor: ListAnchor?) {
        guard let claim, let navigator, navigator.listHold.record(anchor, under: claim) else { return }
        navigator.recorder.listPlace(anchor, in: claim.folderPath)
    }

    private func scroll(to row: Int) {
        requests += 1
        requested = row
        scrollRequest = ScrollRequest(row: row, tick: requests)
    }

    /// The anchor for the message at `row`, by the identity loaded there.
    private static func anchor(atRow row: Int, of model: MessageListViewModel, folderPath: String) -> ListAnchor? {
        let envelope = model.envelope(inSlot: row)
        return ListAnchor(folderPath: folderPath, messageID: envelope?.messageId, uid: envelope?.uid, index: row)
    }

    /// A folder list on the All pill in the default sort, not searching:
    /// its rows are index-addressed, so an anchor means something.
    static func lands(_ model: MessageListViewModel) -> Bool {
        guard let window = model.window, model.folder != nil else { return false }
        return model.filterTab == .all && !model.isSearchActive && window.sortCriterion == .default
    }

    /// `lands`, and no error row above the rows, which shifts their offsets.
    static func records(_ model: MessageListViewModel) -> Bool {
        lands(model) && model.errorMessage == nil
    }

    /// Whether a STATUS has given the folder's count: a total, or an
    /// answered refresh for an empty folder.
    static func countKnown(_ model: MessageListViewModel) -> Bool {
        guard let window = model.window else { return false }
        return window.totalMessages > 0
            || (window.savedMessageCount == nil && model.errorMessage == nil && !model.isLoading)
    }
}

extension View {
    /// Keeps the window's list place for a virtualized message list
    /// (`ListPlaceTracker`). Applied to the list's `ScrollView`.
    func tracksListPlace(
        _ tracker: ListPlaceTracker, model: MessageListViewModel, rowHeight: CGFloat, proxy: ScrollViewProxy
    ) -> some View {
        modifier(ListPlaceTracking(tracker: tracker, model: model, rowHeight: rowHeight, proxy: proxy))
    }
}

/// Reads the model here, not where it is applied: a read in the list view's
/// body would make the whole list depend on the loads.
private struct ListPlaceTracking: ViewModifier {
    let tracker: ListPlaceTracker
    let model: MessageListViewModel
    let rowHeight: CGFloat
    let proxy: ScrollViewProxy
    @Environment(SceneNavigator.self) private var navigator: SceneNavigator?

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Int.self) { geometry in
                ListPlaceGeometry.topRow(
                    contentOffset: geometry.contentOffset.y, topInset: geometry.contentInsets.top,
                    rowHeight: rowHeight
                )
            } action: { _, top in
                tracker.scrolled(toRow: top, model: model)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating { tracker.userScrolled() }
            }
            // Through an observed request, so the scroll runs after the
            // update that laid the rows out; unanimated, as a place is not a
            // journey.
            .onChange(of: tracker.scrollRequest, initial: true) { _, request in
                if let request { proxy.scrollTo(request.slot(in: model), anchor: .top) }
            }
            .onChange(of: ListPlaceTracker.LoadState(model)) { _, _ in tracker.loadsChanged(model: model) }
            .onAppear { tracker.appeared(model, in: navigator) }
            .onDisappear { tracker.disappeared() }
    }
}
