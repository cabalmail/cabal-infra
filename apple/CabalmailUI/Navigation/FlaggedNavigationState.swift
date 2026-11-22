import SwiftUI
import Observation
import CabalmailKit

/// One window's place in the Flagged view, with its transitions: whether
/// the view is up and through which door, the row open in its reader, and
/// the column a collapsed stack shows.
///
/// The third of a window's places, beside `MailNavigationState` and
/// `FeedNavigationState`, and built the same way: the transitions are pure,
/// each returns what follows from it, and `SceneNavigator` applies that to
/// the route and the resume session.
///
/// **Doors.** The view stands in place of one medium's list. On the wide
/// layouts there is one sidebar, and the door is the section the window was
/// in. On the tab layouts each of the Mail and Feeds tabs has a row that
/// opens it, in that tab's own stack; only one is open at a time.
///
/// **Over, not instead.** The window's mail folder and feed list keep their
/// places beneath the view. A pick of either closes it.
///
/// **Backing out.** On a collapsed stack, Back from the view's list returns
/// to the list its door is in and ends the visit, but the door stays named
/// until something else is picked, so the stack's content column goes on
/// drawing the view while it slides away (`isOpen` is false by then).
struct FlaggedNavigationState: Equatable {
    /// What follows from a transition, for the navigator to apply in order.
    enum Record: Equatable {
        /// The view came up through `door`: a new visit.
        case opened(ResumeSession.Section)
        /// The view went: the window is on its folder or feed again.
        case closed
        /// The row open in the view's reader, or none.
        case item(FlaggedRow?)
    }

    /// What waits for the view's list to open once it has appeared and
    /// loaded.
    enum Parked: Equatable {
        /// The row a layout swap closed, whole: it reopens whether or not
        /// the list still holds it.
        case row(FlaggedRow)
        /// A stored route's open item, by identity: the list looks it up.
        case ref(ItemRef)
    }

    /// The medium whose place the view stands in; nil while no stack draws it.
    private(set) var door: ResumeSession.Section?
    /// The row open in the reader.
    private(set) var item: FlaggedRow?
    /// Which column a collapsed stack shows while the view is in it.
    private(set) var column: NavigationSplitViewColumn = .sidebar
    private(set) var parked: Parked?
    /// Counts the visits, so each one builds its list afresh.
    private(set) var visit = 0

    init() {}

    /// The place a stored route names: the view up through `door`, its open
    /// item parked for the list.
    init(door: ResumeSession.Section, item: ItemRef?) {
        self.door = door
        column = .content
        parked = item.map(Parked.ref)
        visit = 1
    }

    /// Whether the window is on the view.
    var isOpen: Bool { door != nil && column != .sidebar }

    // MARK: Transitions

    /// The entry picked through `door`. Picked while the view is already up
    /// there, it closes the reader and shows the list.
    mutating func open(from door: ResumeSession.Section) -> [Record] {
        if isOpen, self.door == door {
            guard item != nil else { return [] }
            item = nil
            column = .content
            return [.item(nil)]
        }
        self.door = door
        item = nil
        parked = nil
        column = .content
        visit += 1
        return [.opened(door)]
    }

    /// Something else was picked, or a navigation took the window away.
    mutating func close() -> [Record] {
        let wasOpen = isOpen
        door = nil
        item = nil
        parked = nil
        column = .sidebar
        return wasOpen ? [.closed] : []
    }

    /// The list's selection: a tap, or the parked row it applied. A row
    /// patched in place (read, a flag) is the same item, and records
    /// nothing.
    mutating func selectItem(_ new: FlaggedRow?) -> [Record] {
        guard isOpen else { return [] }
        guard new?.ref != item?.ref else {
            if let new { item = new }
            return []
        }
        item = new
        column = CompactColumnPolicy.column(hasSelectedMessage: new != nil, current: column)
        return [.item(new)]
    }

    /// A collapsed stack moved column (the back gesture). Leaving the
    /// reader drops the open row, so the same row can be opened again;
    /// leaving the list ends the visit.
    mutating func setColumn(_ new: NavigationSplitViewColumn) -> [Record] {
        guard isOpen, new != column else { return [] }
        column = new
        if new == .sidebar {
            item = nil
            parked = nil
            return [.closed]
        }
        guard CompactColumnPolicy.dropsMessage(movingTo: new), item != nil else { return [] }
        item = nil
        return [.item(nil)]
    }

    /// A tree a layout swap built takes the window over: the open row goes
    /// with the old tree and is parked, so the new tree's list opens it
    /// once that list has appeared (a list and its reader pushed in one
    /// update leave a reader that never loads, #1664), and the column
    /// starts on the list. Nothing is recorded: the window is where it was.
    /// A row already parked, by a tree this one replaced before its list
    /// took it, stays parked.
    mutating func handOff() {
        guard isOpen else { return }
        if let item { parked = .row(item) }
        item = nil
        column = .content
    }

    /// The view moves to stand in `section`'s place, open as it is: the
    /// wide split taking over a view a tab opened.
    mutating func rehome(to section: ResumeSession.Section) {
        guard isOpen else { return }
        door = section
    }

    /// The parked row, once.
    mutating func takeParked() -> Parked? {
        defer { parked = nil }
        return parked
    }
}

/// One main window's Flagged view: its place (`FlaggedNavigationState`) and
/// the list's model, which outlives every view that draws it for as long as
/// the visit lasts. `SceneNavigator` owns one and makes the transitions.
@Observable
@MainActor
final class FlaggedPlace {
    private(set) var state = FlaggedNavigationState()
    @ObservationIgnored private var model: FlaggedListViewModel?

    /// The place a restored window starts on, from its stored route.
    func restore(from route: AppRoute) {
        guard route.smartView == .flagged else { return }
        state = FlaggedNavigationState(door: route.smartDoor ?? route.section, item: route.smartItem?.ref)
    }

    /// Makes a transition on a copy and writes the place only if it
    /// changed, so a write that changes nothing redraws nothing.
    func move(_ transition: (inout FlaggedNavigationState) -> [FlaggedNavigationState.Record])
        -> [FlaggedNavigationState.Record] {
        var next = state
        let records = transition(&next)
        if next != state { state = next }
        return records
    }

    func handOff() {
        var next = state
        next.handOff()
        if next != state { state = next }
    }

    func takeParked() -> FlaggedNavigationState.Parked? {
        guard state.parked != nil else { return nil }
        return state.takeParked()
    }

    func rehome(to section: ResumeSession.Section) {
        state.rehome(to: section)
    }

    /// The visit's model, made on first use for `client`. One per visit:
    /// the view's two doors and every layout tree draw the same rows.
    func list(client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore) -> FlaggedListViewModel {
        if let model { return model }
        let made = FlaggedListViewModel(client: client, preferences: preferences, mailStore: mailStore)
        model = made
        return made
    }

    /// The visit is over: its rows and its pick go, and the next one loads
    /// afresh.
    func endVisit() {
        model = nil
    }
}
