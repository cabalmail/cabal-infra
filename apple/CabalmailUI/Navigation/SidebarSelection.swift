import SwiftUI
import CabalmailKit

/// What a sidebar's list has selected: a mail folder, a feed list, or a view
/// that gathers both media.
///
/// One `List` carries one selection type. The mail sidebar's was `Folder`,
/// so the feeds that share it on the wide layouts could not be rows of its
/// selection and were drawn as buttons instead. With this as the type, a
/// folder row and a feed row are both rows the list selects, by the mouse
/// and by the arrow keys alike.
///
/// A folder is named by its path, not by the fetched `Folder`: the same
/// folder's row and the window's selection stay one value while the folder's
/// counts and attributes change under them.
enum SidebarSelection: Hashable, Sendable {
    case mailFolder(path: String)
    case feedScope(RssItemScope)
    case smartView(SmartView)
}

/// A sidebar entry that lists mail and feed items together.
///
/// No sidebar draws one yet: the type is here so a window's route and the
/// sidebar's selection already have a place for it.
enum SmartView: String, Codable, Hashable, Sendable, CaseIterable {
    /// Flagged messages and flagged feed items.
    case flagged
}

/// How the mail sidebar's list selection maps onto what its window holds: a
/// mail folder, and on the wide layouts a feed list beside it.
///
/// The window keeps the two apart, as the navigator does (a folder pick and a
/// feed pick are different transitions, and each ends a search and records
/// the resume session its own way). The list has one selection. This is the
/// rule between them, pure so it is tested without a list.
struct SidebarListSelection: Equatable {
    /// Whether feed rows are rows of the list's selection: the Mac
    /// (`HostPlatform.sidebarSelectsFeeds`). Elsewhere they are buttons
    /// beside it, and the list's selection is the mail folder's alone.
    let selectsFeeds: Bool

    /// What a pick in the list writes.
    enum Write: Equatable {
        /// The mail folder, or none.
        case folder(Folder?)
        /// A feed list.
        case feedScope(RssItemScope)
        /// Nothing: the pick is not one this list can make.
        case nothing
    }

    /// The row the list shows selected. A feed list on screen is the
    /// selection where the list selects feeds; where it does not, the list
    /// has no selected row while the window shows feeds, since the window
    /// holds no folder then.
    func current(folder: Folder?, feedScope: RssItemScope?) -> SidebarSelection? {
        if selectsFeeds, let feedScope { return .feedScope(feedScope) }
        return folder.map { .mailFolder(path: $0.path) }
    }

    /// What `picked` writes, given the sidebar's fetched `folders` and what
    /// the window holds now.
    ///
    /// A folder row writes the fetched `Folder` for its path, which is the
    /// value the row was drawn from. The list clearing its selection (a
    /// click on the sidebar's empty space) clears the mail folder, as it
    /// always has; while a feed list is the selection it clears nothing,
    /// since a feed row was never a selection the list could clear.
    func write(
        for picked: SidebarSelection?, folders: [Folder], folder: Folder?, feedScope: RssItemScope?
    ) -> Write {
        switch picked {
        case .mailFolder(let path):
            if let fetched = folders.first(where: { $0.path == path }) { return .folder(fetched) }
            return .folder(folder?.path == path ? folder : Folder(path: path))
        case .feedScope(let scope):
            return selectsFeeds ? .feedScope(scope) : .nothing
        case .smartView:
            return .nothing
        case nil:
            return selectsFeeds && feedScope != nil ? .nothing : .folder(nil)
        }
    }

    /// The list's selection as a binding over the window's two.
    ///
    /// - Parameters:
    ///   - folder: the window's mail folder.
    ///   - feedScope: the window's feed list on the layouts where feeds
    ///     share the sidebar; nil where they do not.
    ///   - folders: the sidebar's fetched folders, read when a pick is made.
    func binding(
        folder: Binding<Folder?>, feedScope: Binding<RssItemScope?>?, folders: @escaping @Sendable () -> [Folder]
    ) -> Binding<SidebarSelection?> {
        Binding(
            get: { current(folder: folder.wrappedValue, feedScope: feedScope?.wrappedValue) },
            set: { picked in
                let write = write(
                    for: picked, folders: folders(), folder: folder.wrappedValue,
                    feedScope: feedScope?.wrappedValue
                )
                switch write {
                case .folder(let picked): folder.wrappedValue = picked
                case .feedScope(let scope): feedScope?.wrappedValue = scope
                case .nothing: break
                }
            }
        )
    }
}
