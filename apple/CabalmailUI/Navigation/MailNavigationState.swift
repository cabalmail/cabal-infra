import SwiftUI
import CabalmailKit

/// One window's place in mail, with its transitions: the sidebar's folder,
/// the open message, the column a collapsed split shows, and which of the
/// window's view trees owns them.
///
/// The mail half of what `FeedNavigationState` is for feeds, and built the
/// same way. The transitions are pure: each changes the place and returns
/// what follows from the change, and `SceneNavigator` applies that to the
/// route, the resume session, the folder list's hold and the tab. Nothing
/// here knows about any of those, so every rule can be tested on its own.
///
/// **Trees.** A layout swap builds a new tree while the old one is still
/// being torn down. `gate` is the one member that knows which tree owns the
/// place: a tree sees no folder and no message until it has taken over
/// (`folder(in:)`, `envelope(in:)`, `column(in:)`), and writes from a tree
/// that a newer one has replaced are dropped (`selectMessage`, `setColumn`).
/// A navigator with one tree per window would delete `gate` and the `tree`
/// parameters and nothing else. A tree that was torn down stays able to
/// write for as long as no other has appeared (`TreeGate.canWrite`); a rule
/// that clears it on a layout change would go here.
///
/// **The column after a swap.** A tree that takes the window over starts on
/// the folder's list, and its list reopens the message (`handOff`). The Duo
/// spec's narrowing order, where a focused field wins, then Select mode,
/// then an opened item, is not here yet: it is the rule a later change adds
/// to `handOff`, which is the only place the column is chosen for a tree
/// that did not make the change itself.
///
/// **The open message** is one stored property, `envelope`, read through
/// `envelope(in:)`, and its identity is worked out in one place
/// (`messageRecord(for:in:)`), so holding a `MessageRef` here instead of the
/// envelope changes this type alone.
struct MailNavigationState: Equatable {
    /// What follows from a transition, for the navigator to apply in order.
    enum Record: Equatable {
        /// The window is on another folder, or on none: the route's mail
        /// half starts over there, and the folder list's hold lets go of the
        /// old folder's selection and place.
        case folder(path: String?)
        /// The folder is where the app resumes: the section, the cursor and,
        /// on visionOS, the tab move to it.
        case sessionFolder(path: String)
        /// The message open in the sidebar's folder, for the route and the
        /// cursor.
        case message(MessageRef)
        /// The folder's open message closed.
        case noMessage(folderPath: String)
        /// The search result now open, or none: what a later layout swap
        /// hands to the layout's search surface (#2184). A message opened
        /// outside search is not a result.
        case searchResult(Envelope?)
        /// The collapsed split backed out to the folder list.
        case backedOut
    }

    /// The sidebar's folder: the fetched `Folder` once the folder list has
    /// loaded, a stand-in for its path until then (#1535).
    private(set) var folder: Folder?
    /// The open message. Usually the route's, but a search result while
    /// searching.
    private(set) var envelope: Envelope?
    /// Which column the collapsed navigation shows. Stored rather than
    /// derived from the folder and message, because backing out to the
    /// folder list leaves the folder selected.
    private(set) var column: NavigationSplitViewColumn = .sidebar
    /// The tree that owns the folder, message and column.
    private(set) var gate = TreeGate()

    // MARK: Trees

    /// The sidebar folder as `tree` should draw it: none until the tree has
    /// taken over.
    func folder(in tree: UUID) -> Folder? {
        gate.shows(tree) ? folder : nil
    }

    /// The open message as `tree` should draw it: none until the tree has
    /// taken over.
    func envelope(in tree: UUID) -> Envelope? {
        gate.shows(tree) ? envelope : nil
    }

    /// The compact column as `tree` should draw it: the folder list until
    /// the tree has taken over.
    func column(in tree: UUID) -> NavigationSplitViewColumn {
        gate.shows(tree) ? column : .sidebar
    }

    /// A mail tree appeared; whether it replaces another (`TreeGate`).
    mutating func appear(_ tree: UUID, startsOnFolderList: Bool) -> Bool {
        gate.appear(tree, startsOnFolderList: startsOnFolderList)
    }

    mutating func mount(_ tree: UUID) {
        gate.mount(tree)
    }

    func isAppearing(_ tree: UUID) -> Bool {
        gate.isAppearing(tree)
    }

    func isSuperseded(_ tree: UUID) -> Bool {
        gate.isSuperseded(tree)
    }

    /// A tree a layout swap built takes the window over: the folder stays,
    /// the open message goes with the old list, for the navigator to park
    /// from the route so the new list selects it once it has appeared and
    /// loaded, and the column starts on that folder's list. Nothing is
    /// recorded: the window is where it was.
    mutating func handOff() {
        envelope = nil
        column = CompactColumnPolicy.afterFolderChange(hasFolder: folder != nil)
    }

    // MARK: Transitions

    /// The window moves to `new`: a sidebar pick, a landing, a navigation,
    /// or the wide split clearing mail for a feed.
    ///
    /// A same-path write is a metadata reconcile, the stand-in
    /// `Folder(path:)` swapped for the fetched one: same mailbox, so the
    /// message stays and nothing is recorded. Any other folder closes the
    /// open message and shows its list, or the folder list when it cleared.
    ///
    /// - Parameter movesSession: whether a new folder is where the app
    ///   resumes. Only a landing before the window has shown mail passes
    ///   false.
    mutating func setFolder(_ new: Folder?, movesSession: Bool = true) -> [Record] {
        guard new?.path != folder?.path else {
            if new != folder { folder = new }
            return []
        }
        folder = new
        envelope = nil
        column = CompactColumnPolicy.afterFolderChange(hasFolder: new != nil)
        guard let path = new?.path, movesSession else { return [.folder(path: new?.path)] }
        return [.folder(path: path), .sessionFolder(path: path)]
    }

    /// The open message changes, whichever tree asks: a hand-off, the wide
    /// split clearing mail for a feed, or a column move closing the reader.
    /// The same message again changes nothing.
    ///
    /// While searching, the open message is a result with no single folder
    /// to anchor the cursor to, so only the result is recorded.
    mutating func openMessage(_ new: Envelope?, isSearching: Bool) -> [Record] {
        guard new != envelope else { return [] }
        envelope = new
        column = CompactColumnPolicy.column(hasSelectedMessage: new != nil, current: column)
        let result = Record.searchResult(isSearching ? new : nil)
        guard !isSearching, let folderPath = folder?.path else { return [result] }
        return [result] + Self.messageRecord(for: new, in: folderPath)
    }

    /// The list's selection from `tree`: a tap, a restore, an advance after
    /// a dispose.
    mutating func selectMessage(_ new: Envelope?, isSearching: Bool, from tree: UUID) -> [Record] {
        guard gate.canWrite(tree) else { return [] }
        return openMessage(new, isSearching: isSearching)
    }

    /// The collapsed split moved column from `tree` (the back gesture).
    /// Leaving the reader drops the open message, so the same row can be
    /// opened again.
    mutating func setColumn(
        _ new: NavigationSplitViewColumn, isSearching: Bool, from tree: UUID
    ) -> [Record] {
        guard gate.canWrite(tree), new != column else { return [] }
        column = new
        let backedOut: [Record] = new == .sidebar ? [.backedOut] : []
        guard CompactColumnPolicy.dropsMessage(movingTo: new) else { return backedOut }
        return backedOut + openMessage(nil, isSearching: isSearching)
    }

    /// What the route and the cursor record for `envelope` open in the
    /// folder at `folderPath`. Anchored to the sidebar's folder: a row from
    /// another folder is not this folder's position, and records nothing.
    private static func messageRecord(for envelope: Envelope?, in folderPath: String) -> [Record] {
        guard let envelope else { return [.noMessage(folderPath: folderPath)] }
        let ref = envelope.ref(defaultFolder: folderPath)
        return ref.folder == folderPath ? [.message(ref)] : []
    }
}
