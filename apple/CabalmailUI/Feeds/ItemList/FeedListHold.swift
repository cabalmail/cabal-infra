import SwiftUI
import CabalmailKit

/// The split's feed list as it moves between its list column and the panel
/// below a laptop fold (#1649): the list mounting next for the same scope
/// takes the one that went away, its model (rows, pages loaded, filter,
/// search) and the item at its top, instead of reloading the store and
/// syncing from scratch.
///
/// The feed twin of `FolderListHold`'s move, and the same claim rule: a list
/// records only under the claim it took when it mounted, and a move voids
/// it, so the outgoing list's teardown can neither record nor take what is
/// parked for its successor. `SplitShell` holds one and publishes it as
/// `\.feedListHold`, so it goes with the split and hands nothing across a
/// shell swap. Not `@Observable`: no view body reads it.
@MainActor
final class FeedListHold {
    /// A mounted list's right to record into the hold.
    struct Claim: Equatable {
        fileprivate let generation: Int
    }

    /// What a move hands the next list for the same scope.
    struct Handoff {
        let model: FeedItemListViewModel
        let title: String
        /// The item at the top of the list that went away.
        let topItemID: String?
    }

    private struct Held {
        let scope: RssItemScope
        let model: FeedItemListViewModel
        let title: String
        var topItemID: String?
    }

    private var held: Held?
    private var handsOff = false
    private var generation = 0

    /// A list mounting for `scope`: the moved list's state, once, when a
    /// move is handing it over for that scope; and the claim it records
    /// under. A list for another scope starts afresh, and the held list goes.
    func mount(scope: RssItemScope) -> (claim: Claim, handoff: Handoff?) {
        defer { handsOff = false }
        generation += 1
        let claim = Claim(generation: generation)
        guard let held, held.scope == scope else {
            self.held = nil
            return (claim, nil)
        }
        guard handsOff else { return (claim, nil) }
        return (claim, Handoff(model: held.model, title: held.title, topItemID: held.topItemID))
    }

    /// The mounted list's model, under its claim.
    func register(_ model: FeedItemListViewModel, scope: RssItemScope, title: String, under claim: Claim) {
        guard holds(claim) else { return }
        let top = held.flatMap { $0.model === model ? $0.topItemID : nil }
        held = Held(scope: scope, model: model, title: title, topItemID: top)
    }

    /// The item at the top of the mounted list, as it scrolls. Refused under
    /// a voided claim, which is the outgoing list going away.
    func record(topItemID: String?, under claim: Claim) {
        guard holds(claim), held != nil else { return }
        held?.topItemID = topItemID
    }

    /// The list is moving: the next list for its scope takes it, and the
    /// moving list's claim is void.
    func move() {
        handsOff = held != nil
        generation += 1
    }

    func holds(_ claim: Claim) -> Bool {
        claim.generation == generation
    }
}

extension EnvironmentValues {
    /// The split's feed list hold (`FeedListHold`); nil outside the split.
    @Entry var feedListHold: FeedListHold?
}
