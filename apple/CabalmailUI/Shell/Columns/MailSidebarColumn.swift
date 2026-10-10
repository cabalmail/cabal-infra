import SwiftUI
import CabalmailKit

/// The mail sidebar every shell shows: a header slot, then the folder list
/// (and, on the wide shells, the feeds section), over the sidebar wash.
///
/// The header is the shell's: the Mac heads its sidebar with the Cabalmail
/// mark, below the traffic lights and above the folder list's own header.
/// The wide shells pass the filter field's text and the feeds selection,
/// which render inside the list's own header (`SidebarListHeaderRow`); a
/// shell that passes neither gets the list's own `.searchable` and toolbar.
struct MailSidebarColumn<Header: View>: View {
    let selection: Binding<Folder?>
    /// The wide shells' "Filter folders" text; nil keeps the list's own.
    var filter: Binding<String>?
    /// The wide shells' Feeds section selection; nil hides the section.
    var feedSelection: Binding<RssItemScope?>?
    /// The Cabalmail mark in place of the list's "Folders" title, at this
    /// size (`brandMarkTitle` in `SidebarBranding.swift`; the list's
    /// `.navigationTitle` string stays for VoiceOver and the back button).
    /// Nil leaves the title alone, as the Mac's sidebar, which shows none.
    /// Every shell says which, so a sidebar can't lose its mark by omission.
    let titleMarkSize: CGFloat?
    /// The first folder load, which finishes the window's launch landing
    /// (`SceneNavigator.foldersLoaded`).
    let onFoldersLoaded: ([Folder]) -> Void
    @ViewBuilder let header: () -> Header

    var body: some View {
        if let titleMarkSize {
            column.brandMarkTitle(size: titleMarkSize)
        } else {
            column
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            header()
            FolderListView(
                selection: selection,
                externalFilter: filter,
                feedSelection: feedSelection,
                onFoldersLoaded: onFoldersLoaded
            )
        }
        // Sidebar branding (see `SidebarBranding.swift`): the wash paints this
        // column only — the entire folder screen on compact iPhone, where
        // this column IS the screen; the floating sidebar on iPad; the sidebar
        // material on macOS. Hiding the list's scroll background (inherited by
        // the folder `List` below) lets the wash show through the native
        // material instead of being painted over by the system background.
        .scrollContentBackground(.hidden)
        .background { SidebarWash().ignoresSafeArea() }
    }
}
