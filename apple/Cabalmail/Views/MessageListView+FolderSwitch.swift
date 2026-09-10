import SwiftUI
import CabalmailKit

// The folder-switch menu: the folder name at the top of the message list
// is a tappable affordance that opens the other folders. Pulled into a
// sibling extension so the primary MessageListView body stays under
// SwiftLint's `type_body_length` cap.
//
// The folder name is already the list's navigation title everywhere. On
// iOS, iPadOS and visionOS the menu is the system's own title menu
// (`toolbarTitleMenu`): the inline title gains the platform chevron and a
// tap opens the menu. macOS draws that title as bold text at the leading
// edge of the content column's toolbar section but never materializes a
// title menu for it (probed on macOS 26: neither the column's nor the
// window's `toolbarTitleMenu` adds a chevron or opens on click), so the Mac
// removes the toolbar's title text and puts a `Menu` in the same slot — a
// `.navigation` toolbar item with the bold name and a chevron. The window
// keeps its title for the Window menu and Mission Control. Nothing is drawn
// in the list's own action bar: a second copy of the folder name a row
// below the title read as a redundancy on the Mac.
//
// The rows are `Toggle`s rather than buttons drawing a checkmark glyph, so
// the folder in effect carries the native mark an assistive client reads
// (#1367), which on macOS brings the materialize-once behaviour the sort
// menu documents (#1329, #1337): the identity carries what the rows draw.
extension MessageListView {
    /// The menu's rows for the folder list loaded so far, with the current
    /// folder checked.
    var folderSwitchGroups: FolderSwitchMenuPolicy.Groups {
        FolderSwitchMenuPolicy.groups(folders: switchFolders, current: folder)
    }

    /// Hangs the folder menu on `content`'s title. The search surface's
    /// title is "Search", not a folder, so it keeps the plain title.
    @ViewBuilder
    func folderSwitchTitle<Content: View>(_ content: Content) -> some View {
        if isSearchScope {
            content
        } else {
            #if os(macOS)
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) { folderSwitchMenu }
                }
            #else
            content.toolbarTitleMenu { folderSwitchMenuItems }
            #endif
        }
    }

    #if os(macOS)
    /// macOS: the folder name, bold like the toolbar title it stands in
    /// for, as a menu with the system's pull-down chevron.
    @ViewBuilder
    var folderSwitchMenu: some View {
        let groups = folderSwitchGroups
        Menu {
            folderSwitchMenuItems
        } label: {
            Text(folder.name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityLabel("Folder, \(folder.name)")
        .accessibilityHint("Switch folder")
        .accessibilityIdentifier("list.folderSwitch")
        // macOS keeps the AppKit menu it built the first time this `Menu`
        // was opened — checkmarks and row titles included — so the identity
        // carries what the rows draw (#1337, same mechanism as #1329).
        .id(FolderSwitchMenuPolicy.identity(groups))
    }
    #endif

    /// The menu body: subscribed folders, then an "Other folders" submenu
    /// for the rest when there are any.
    @ViewBuilder
    var folderSwitchMenuItems: some View {
        let groups = folderSwitchGroups
        folderSwitchRows(groups.subscribed)
        if !groups.other.isEmpty {
            Divider()
            Menu(FolderSwitchMenuPolicy.otherFoldersLabel) {
                folderSwitchRows(groups.other)
            }
        }
    }

    @ViewBuilder
    private func folderSwitchRows(_ rows: [ReaderMenuRow<Folder>]) -> some View {
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in
                    // Re-picking the folder the list is on is a no-op: the
                    // parent would only re-key the same view.
                    guard !row.isOn else { return }
                    onSwitchFolder(row.option)
                }
            )) {
                Label(row.label, systemImage: FolderPickerRow<EmptyView>.icon(for: row.option))
            }
        }
    }

    /// Fetches the folder list the menu offers. One `/list_folders` per
    /// folder mount — the view is re-keyed per folder, so the list is as
    /// fresh as the sidebar's own — and a failure just leaves the menu
    /// showing the current folder alone.
    func loadFolderSwitchChoices() async {
        guard !isSearchScope, let client = appState.client else { return }
        do {
            try await client.imapClient.connectAndAuthenticate()
            switchFolders = try await client.imapClient.listFolders()
        } catch {
            // The menu falls back to the current folder; the sidebar
            // surfaces folder-list errors in its own chrome.
        }
    }
}
