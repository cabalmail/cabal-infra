import SwiftUI
import CabalmailKit

/// One window's place in the feed reader, with its transitions.
///
/// Both feed trees read and write it: the wide split, where `MailRootView`
/// hosts feeds beside mail, and `FeedRootView`, the Feeds tab on the compact
/// layout and on visionOS. Before, each kept its own copy as view state and
/// they disagreed on when a restored item opens; a layout swap threw both
/// away. The transitions are pure: each returns what the resume session
/// should record, and `SceneNavigator` records it.
///
/// **One restore rule (#1664).** Picking a scope never selects an item in
/// the same transition. An item parked for the scope (a launch restore, a
/// tapped feed banner, a layout swap's hand-off) is the item list's to apply,
/// once it has appeared and loaded (`FeedItemListView`). On a compact stack,
/// a list and its reader pushed in one update leave a reader that never
/// loads; the wide layouts now wait the same way.
struct FeedNavigationState: Equatable {
    /// What the resume session should record after a transition.
    enum Record: Equatable {
        case scope(RssItemScope?)
        case item(RssItem?)
    }

    /// The feed list on screen: a subscription, a folder, or all feeds.
    private(set) var scope: RssItemScope?
    /// The item open in the reader.
    private(set) var item: RssItem?
    /// Which column the collapsed Feeds split shows (`FeedRootView`).
    private(set) var column: NavigationSplitViewColumn = .sidebar
    /// The tree that owns the reader's state.
    private(set) var gate = TreeGate()
    /// Whether this window has landed in feeds: reopened the session's scope,
    /// or been sent to one. Never reset.
    private(set) var didLand = false

    // MARK: Trees

    func scope(in tree: UUID) -> RssItemScope? {
        gate.shows(tree) ? scope : nil
    }

    func item(in tree: UUID) -> RssItem? {
        gate.shows(tree) ? item : nil
    }

    func column(in tree: UUID) -> NavigationSplitViewColumn {
        gate.shows(tree) ? column : .sidebar
    }

    /// A feed tree appeared; whether it replaces another (`TreeGate`).
    mutating func appear(_ tree: UUID) -> Bool {
        gate.appear(tree)
    }

    mutating func mount(_ tree: UUID) {
        gate.mount(tree)
    }

    func isAppearing(_ tree: UUID) -> Bool {
        gate.isAppearing(tree)
    }

    mutating func markLanded() {
        didLand = true
    }

    /// A tree a layout swap built takes the reader over: the open item is
    /// handed back for the caller to park, so the new list selects it once it
    /// has appeared and loaded, and the column starts on that list. Nothing
    /// is recorded: the window is where it was.
    mutating func takeItemForHandOff() -> RssItem? {
        defer {
            item = nil
            column = scope == nil ? .sidebar : .content
        }
        return item
    }

    // MARK: Transitions

    /// A scope picked: from a sidebar, the list's scope switcher, a landing
    /// or a navigation. The open item goes with the old list; one parked for
    /// the new scope is the list's to apply (see the type's doc). Picking the
    /// scope on screen changes nothing.
    mutating func selectScope(_ new: RssItemScope?) -> [Record] {
        guard new != scope else { return [] }
        return openScope(new)
    }

    /// `selectScope`, for a scope that wasn't on screen even if it is the one
    /// held: the wide split showing mail keeps the compact Feeds tab's place,
    /// and a pick there starts that scope afresh.
    mutating func openScope(_ new: RssItemScope?) -> [Record] {
        scope = new
        item = nil
        column = new == nil ? .sidebar : .content
        return [.scope(new)]
    }

    /// The list's selection from `tree`: a tap, or a restore it applied.
    mutating func selectItem(_ new: RssItem?, from tree: UUID) -> [Record] {
        guard gate.canWrite(tree), new != item else { return [] }
        item = new
        column = CompactColumnPolicy.column(hasSelectedMessage: new != nil, current: column)
        return [.item(new)]
    }

    /// The collapsed split moved column from `tree` (the back gesture).
    /// Leaving the reader drops the open item, so the same row can be opened
    /// again.
    mutating func setColumn(_ new: NavigationSplitViewColumn, from tree: UUID) -> [Record] {
        guard gate.canWrite(tree), new != column else { return [] }
        column = new
        guard CompactColumnPolicy.dropsMessage(movingTo: new), item != nil else { return [] }
        item = nil
        return [.item(nil)]
    }
}
