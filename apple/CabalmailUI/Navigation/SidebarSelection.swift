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
enum SmartView: String, Codable, Hashable, Sendable, CaseIterable {
    /// Flagged messages and flagged feed items.
    case flagged

    /// The view's name: its sidebar entry, its list's title and its
    /// window's. "Flagged" is a fixed word, not the built-in flag's name:
    /// the view lists what carries any flag.
    var title: String {
        switch self {
        case .flagged: return "Flagged"
        }
    }
}

/// How the mail sidebar's list selection maps onto what its window holds: a
/// mail folder, on the wide layouts a feed list beside it, and a smart view
/// over either.
///
/// The window keeps them apart, as the navigator does (a folder pick, a
/// feed pick and a smart view's are different transitions, and each ends a
/// search and records the resume session its own way). The list has one
/// selection. This is the rule between them, pure so it is tested without a
/// list.
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
        /// A view of both media.
        case smartView(SmartView)
        /// Nothing: the pick is not one this list can make.
        case nothing
    }

    /// The row the list shows selected. A smart view the window is on is
    /// the selection wherever the list offers its row: the folder and the
    /// feed list keep their places beneath it, and neither is the row. A
    /// feed list on screen is the selection where the list selects feeds;
    /// where it does not, the list has no selected row while the window
    /// shows feeds, since the window holds no folder then.
    func current(folder: Folder?, feedScope: RssItemScope?, smartView: SmartView? = nil) -> SidebarSelection? {
        if let smartView { return .smartView(smartView) }
        if selectsFeeds, let feedScope { return .feedScope(feedScope) }
        return folder.map { .mailFolder(path: $0.path) }
    }

    /// What `picked` writes, given the sidebar's fetched `folders` and what
    /// the window holds now.
    ///
    /// A folder row writes the fetched `Folder` for its path, which is the
    /// value the row was drawn from. The list clearing its selection (a
    /// click on the sidebar's empty space) clears the mail folder, as it
    /// always has; while a feed list or a smart view is the selection it
    /// clears nothing, since neither was ever a selection the list could
    /// clear.
    func write(
        for picked: SidebarSelection?, folders: [Folder], folder: Folder?, feedScope: RssItemScope?,
        smartView: SmartView? = nil
    ) -> Write {
        switch picked {
        case .mailFolder(let path):
            if let fetched = folders.first(where: { $0.path == path }) { return .folder(fetched) }
            return .folder(folder?.path == path ? folder : Folder(path: path))
        case .feedScope(let scope):
            return selectsFeeds ? .feedScope(scope) : .nothing
        case .smartView(let view):
            return .smartView(view)
        case nil:
            if smartView != nil { return .nothing }
            return selectsFeeds && feedScope != nil ? .nothing : .folder(nil)
        }
    }

    /// The list's selection as a binding over the window's two.
    ///
    /// - Parameters:
    ///   - folder: the window's mail folder.
    ///   - feedScope: the window's feed list on the layouts where feeds
    ///     share the sidebar; nil where they do not.
    ///   - smartView: the smart view the window is on, where the list
    ///     offers a row for one; nil where it offers none.
    ///   - folders: the sidebar's fetched folders, read when a pick is made.
    func binding(
        folder: Binding<Folder?>, feedScope: Binding<RssItemScope?>?, smartView: Binding<SmartView?>? = nil,
        folders: @escaping @Sendable () -> [Folder]
    ) -> Binding<SidebarSelection?> {
        Binding(
            get: {
                current(
                    folder: folder.wrappedValue, feedScope: feedScope?.wrappedValue,
                    smartView: smartView?.wrappedValue
                )
            },
            set: { picked in
                let write = write(
                    for: picked, folders: folders(), folder: folder.wrappedValue,
                    feedScope: feedScope?.wrappedValue, smartView: smartView?.wrappedValue
                )
                switch write {
                case .folder(let picked): folder.wrappedValue = picked
                case .feedScope(let scope): feedScope?.wrappedValue = scope
                case .smartView(let view): smartView?.wrappedValue = view
                case .nothing: break
                }
            }
        )
    }
}
