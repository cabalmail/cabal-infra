import CabalmailKit

/// Tab identities for the tab-bar layouts: the compact tab bar (`TabShell`)
/// and visionOS's (`OrnamentShell`). `resumeSection` maps the content tabs
/// onto the resume session's sections; the utility tabs have none. Folders
/// is visionOS's alone (the compact Mail tab browses folders in its own
/// sidebar), and belongs to mail.
///
/// The tab lists are data (`tabs(for:)`): each shell draws the list for its
/// layout, with each tab's title, symbol and role, so the two bars can't
/// drift and a change to one tab is one value here.
enum CompactTab: Hashable {
    case mail, folders, feeds, addresses, settings, search

    /// A tab's role in its bar. App-owned rather than SwiftUI's `TabRole`,
    /// so the lists are tested without building a tab view; `TabShell`
    /// maps `.search` onto `TabRole.search`.
    enum Role: Equatable {
        case search
    }

    var resumeSection: ResumeSession.Section? {
        switch self {
        case .mail, .folders: return .mail
        case .feeds: return .feeds
        case .addresses, .settings, .search: return nil
        }
    }

    /// The tab a freshly built tab tree opens on: Feeds when the resume
    /// session (live or stored) ended in the feed reader, Mail otherwise.
    /// The utility tabs are never a landing — they are not sections of the
    /// session, so nothing can ask for them.
    static func initial(for section: ResumeSession.Section?) -> CompactTab {
        section == .feeds ? .feeds : .mail
    }

    /// The tab's label in its bar.
    var title: String {
        switch self {
        case .mail: return "Mail"
        case .folders: return "Folders"
        case .feeds: return "Feeds"
        case .addresses: return "Addresses"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    /// The tab's SF Symbol.
    var systemImage: String {
        switch self {
        case .mail: return "tray"
        case .folders: return "folder"
        case .feeds: return "dot.radiowaves.up.forward"
        case .addresses: return "at"
        case .settings: return "gear"
        case .search: return "magnifyingglass"
        }
    }

    /// The tab's role on `layout`. The phone's Search tab takes the search
    /// role, which on iOS 26 and later — with its field activating on
    /// selection (`TabShell`) — sets it apart at the bar's trailing end and
    /// morphs it into the search field. visionOS keeps a plain Search tab in
    /// its ornament.
    ///
    /// Not while the bars are vertical (`\.barsAreVertical`, iPhone Duo's
    /// outer display): there the system can hand the search role's button to
    /// the selected tab's own search field instead, so from Addresses it
    /// opened "Filter addresses" (#1963; measured in both landscapes, while
    /// portrait opened Search). A plain Search tab in the strip opens the
    /// Search screen from every tab.
    func role(in layout: ShellLayout, barsAreVertical: Bool = false) -> Role? {
        self == .search && layout == .tabs && !barsAreVertical ? .search : nil
    }

    /// The tabs `layout` draws, in order. The phone has no Folders tab: its
    /// Mail tab's sidebar browses and manages folders. visionOS's Mail tab
    /// has no sidebar, so Folders is a tab of its own, second. The wide
    /// shells have no tab bar.
    static func tabs(for layout: ShellLayout) -> [CompactTab] {
        switch layout {
        case .tabs: return [.mail, .feeds, .addresses, .settings, .search]
        case .ornament: return [.mail, .folders, .feeds, .addresses, .settings, .search]
        case .desktop, .split: return []
        }
    }
}
