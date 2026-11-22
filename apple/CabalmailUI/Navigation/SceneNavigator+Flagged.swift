import SwiftUI
import CabalmailKit

// The window's Flagged view (`FlaggedPlace`, `FlaggedNavigationState`): what
// each tree reads, the writes it makes, and the one place a transition's
// records are applied. Here rather than in `SceneNavigator.swift` so that
// file keeps to its length; the route is written through `setSmartRoute`,
// the one member that has to live there.
extension SceneNavigator {
    /// The door a tree draws the view through: its own medium's on the tab
    /// layouts, where the Mail and the Feeds tab each have one, and the
    /// window's section on the wide ones, whose one sidebar has one entry.
    enum FlaggedDoor {
        case mail
        case feeds
        /// The wide split: the view stands in the section the window is in.
        case split
    }

    private func section(of door: FlaggedDoor) -> ResumeSession.Section {
        switch door {
        case .mail: return .mail
        case .feeds: return .feeds
        case .split: return route.section
        }
    }

    /// Whether `tree` owns the place behind `door`, by the gate of the
    /// medium the door belongs to: a tree a layout swap built sees nothing
    /// until it has taken over, and one being torn down cannot write.
    private func gate(of door: FlaggedDoor) -> TreeGate {
        section(of: door) == .feeds ? feeds.gate : mail.gate
    }

    /// Whether `tree` draws the Flagged list in its content column: the
    /// view was opened through this door. Still true once a collapsed stack
    /// has backed out of it, until something else is picked, so the column
    /// goes on drawing the view while it slides away.
    func flaggedOccupies(_ tree: UUID, door: FlaggedDoor) -> Bool {
        flaggedPlace.state.door == section(of: door) && gate(of: door).shows(tree)
    }

    /// Whether the window is on the Flagged view as `tree` draws it: its
    /// entry is the sidebar's selected row, and its reader the detail.
    func flaggedIsOpen(in tree: UUID, door: FlaggedDoor) -> Bool {
        flaggedPlace.state.isOpen && flaggedOccupies(tree, door: door)
    }

    /// Whether the Flagged view is what the window shows in front: over the
    /// split, or in the tab on screen. What the window's title follows.
    var flaggedIsInFront: Bool {
        guard flaggedPlace.state.isOpen, let door = flaggedPlace.state.door else { return false }
        if layoutIsWide { return door == route.section }
        return (door == .mail && compactTab == .mail) || (door == .feeds && compactTab == .feeds)
    }

    /// The row open in the view's reader, as `tree` should draw it.
    func flaggedItem(in tree: UUID, door: FlaggedDoor) -> FlaggedRow? {
        flaggedIsOpen(in: tree, door: door) ? flaggedPlace.state.item : nil
    }

    /// The entry picked in `tree`'s list. A pick of the entry already
    /// selected still comes through here, which is what lets a wide shell
    /// end a search on it.
    func showFlagged(from tree: UUID, door: FlaggedDoor) {
        guard gate(of: door).canWrite(tree) else { return }
        let section = section(of: door)
        applyFlagged(flaggedPlace.move { $0.open(from: section) })
        // visionOS's Folders tab picks the view for its Mail tab, as it
        // picks a folder.
        if compactTab == .folders { showTab(.mail) }
        // A pick in the split is where a swap to the tab layout opens.
        followSplit()
    }

    /// The Flagged list's selection from `tree`: a tap, or the parked row
    /// it applied.
    func selectFlaggedItem(_ row: FlaggedRow?, from tree: UUID, door: FlaggedDoor) {
        guard flaggedIsOpen(in: tree, door: door), gate(of: door).canWrite(tree) else { return }
        let records = flaggedPlace.move { $0.selectItem(row) }
        applyFlagged(records)
        if !records.isEmpty { followSplit() }
    }

    /// The column a collapsed stack shows while the view occupies it.
    func flaggedColumn(in tree: UUID, door: FlaggedDoor) -> NavigationSplitViewColumn? {
        flaggedOccupies(tree, door: door) ? flaggedPlace.state.column : nil
    }

    /// A collapsed stack moved column from `tree` (the back gesture) while
    /// the view occupies it. Returns false when the move is not the view's:
    /// the stack backed out of it earlier and is moving on to its own list,
    /// which lets go of the door.
    func setFlaggedColumn(_ column: NavigationSplitViewColumn, from tree: UUID, door: FlaggedDoor) -> Bool {
        guard flaggedOccupies(tree, door: door) else { return false }
        guard flaggedPlace.state.isOpen else {
            closeFlagged()
            return false
        }
        guard gate(of: door).canWrite(tree) else { return true }
        let records = flaggedPlace.move { $0.setColumn(column) }
        applyFlagged(records)
        if records.contains(.closed) { backOutBeneath(door) }
        return true
    }

    /// Back from the view's list is Back to its door's own list, so the
    /// medium beneath goes there with it, as its own Back leaves it: nothing
    /// picked, which puts it on its first column. A stack that opened the
    /// view from that list is there already. One a layout swap built is
    /// not: the wide layout always has a folder or a feed list open beneath
    /// the view, and a picked row in the list the stack lands on pushes it
    /// forward again.
    private func backOutBeneath(_ door: FlaggedDoor) {
        switch section(of: door) {
        case .mail: selectFolder(nil)
        case .feeds: selectFeedScope(nil)
        }
    }

    /// The window's own medium was picked or navigated to: the view closes
    /// where it stood in that medium's place, and on the wide layouts,
    /// whose one sidebar holds both.
    func flaggedGivesWay(to section: ResumeSession.Section) {
        guard layoutIsWide || flaggedPlace.state.door == section else { return }
        closeFlagged()
    }

    private func closeFlagged() {
        applyFlagged(flaggedPlace.move { $0.close() })
    }

    /// A tree a layout swap built is taking the window over
    /// (`FlaggedNavigationState.handOff`). Returns whether the view was
    /// what the window showed in front as the swap began, read before the
    /// layout changes under it.
    func flaggedTreeChanged() -> Bool {
        let wasInFront = flaggedIsInFront
        flaggedPlace.handOff()
        return wasInFront
    }

    /// The wide split took over a window that had the view in front: the
    /// view stands in the split's section, whichever tab it was opened in.
    /// The split may have moved that section as it took over (a Feeds tab
    /// with no list open has nothing for the split to show but mail), and
    /// the view goes with it rather than staying behind a door the split
    /// does not have.
    func flaggedFollowsSection() {
        guard flaggedPlace.state.isOpen, flaggedPlace.state.door != route.section else { return }
        flaggedPlace.rehome(to: route.section)
        setSmartRoute(.flagged, door: route.section, item: route.smartItem?.ref)
    }

    /// The row parked for the view's list in `tree`, once: the row a layout
    /// swap closed, or a restored window's open item.
    func takeParkedFlaggedItem(in tree: UUID, door: FlaggedDoor) -> FlaggedNavigationState.Parked? {
        guard flaggedIsOpen(in: tree, door: door), gate(of: door).canWrite(tree) else { return nil }
        return flaggedPlace.takeParked()
    }

    /// The visit's list model (`FlaggedPlace.list`).
    func flaggedList(
        client: CabalmailClient, preferences: Preferences, mailStore: MailSessionStore
    ) -> FlaggedListViewModel {
        flaggedPlace.list(client: client, preferences: preferences, mailStore: mailStore)
    }

    /// Applies a Flagged transition's records to the route and the resume
    /// session.
    ///
    /// The route names the view, its door and its open row, so a window the
    /// system restores reopens on them. The resume session, which a new
    /// window and another device pick up from, has no place for the view:
    /// an open row records what its own medium's reader records (a message
    /// in its own folder, an article in its own feed's list). When the row
    /// closes, the session records that too, as that reader's Back does,
    /// and then goes back to the folder or feed beneath, if there is one.
    private func applyFlagged(_ records: [FlaggedNavigationState.Record]) {
        for record in records {
            // The row the reader had open, read before the route moves on.
            let wasOpen = route.smartItem?.ref
            switch record {
            case .opened(let door):
                setSmartRoute(.flagged, door: door, item: nil)
            case .closed:
                setSmartRoute(nil, door: nil, item: nil)
                flaggedPlace.endVisit()
                recordFlaggedItemClosed(wasOpen)
            case .item(let row):
                setSmartRoute(.flagged, door: flaggedPlace.state.door, item: row?.ref)
                if let row { recordFlaggedItem(row) } else { recordFlaggedItemClosed(wasOpen) }
            }
        }
    }

    private func recordFlaggedItem(_ row: FlaggedRow) {
        switch row {
        case .mail(_, let ref):
            recorder.folder(ref.folder)
            recorder.message(ref)
        case .feed(let item):
            if !item.subscriptionId.isEmpty { recorder.feedScope(.subscription(item.subscriptionId)) }
            recorder.feedItem(item)
        }
    }

    /// The view's reader closed on `ref`, or the view closed around it. The
    /// session stops naming the row as open before it is handed the place
    /// beneath: with no folder or feed list beneath (the view opened from a
    /// tab's first column) that hand-over leaves the half alone, and the
    /// row would stay recorded as open, for the next layout or another
    /// device to reopen.
    private func recordFlaggedItemClosed(_ ref: ItemRef?) {
        switch ref {
        case .mail(let message): recorder.noMessage(folderPath: message.folder)
        case .feed: recorder.feedItem(nil)
        case nil: break
        }
        becameLastUsed()
    }
}
