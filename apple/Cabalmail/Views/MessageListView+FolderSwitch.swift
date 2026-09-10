import SwiftUI
import CabalmailKit

// The folder-switch menu: the folder name at the top of the message list
// is a tappable affordance that opens the other folders. Pulled into a
// sibling extension so the primary MessageListView body stays under
// SwiftLint's `type_body_length` cap.
//
// Where it hangs differs by platform. iOS, iPadOS and visionOS already show
// the folder name as the inline navigation title, so the menu is the
// system's own title menu (`toolbarTitleMenu`): the title gains a chevron
// and a tap opens the menu. macOS shows no column title — the window title
// is the open message's subject — so the list's action bar gains a folder
// menu at its leading edge (`folderSwitchMenu`, drawn by `+Filter`).
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

    /// Hangs the title menu on `content` on the platforms that show the
    /// folder name as a navigation title. The search surface's title is
    /// "Search", not a folder, so it gets no menu.
    @ViewBuilder
    func folderSwitchTitle<Content: View>(_ content: Content) -> some View {
        #if os(iOS) || os(visionOS)
        if isSearchScope {
            content
        } else {
            content.toolbarTitleMenu { folderSwitchMenuItems }
        }
        #else
        content
        #endif
    }

    /// macOS: the folder name with a disclosure chevron, opening the menu.
    /// Sits at the leading edge of the list's action bar.
    @ViewBuilder
    var folderSwitchMenu: some View {
        let groups = folderSwitchGroups
        Menu {
            folderSwitchMenuItems
        } label: {
            HStack(spacing: 4) {
                Text(folder.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Folder, \(folder.name)")
        .accessibilityHint("Switch folder")
        .accessibilityIdentifier("list.folderSwitch")
        // macOS keeps the AppKit menu it built the first time this `Menu`
        // was opened — checkmarks and row titles included — so the identity
        // carries what the rows draw (#1337, same mechanism as #1329).
        .id(FolderSwitchMenuPolicy.identity(groups))
    }

    /// The menu body shared by the title menu and the macOS action-bar
    /// menu: subscribed folders, then an "Other folders" submenu for the
    /// rest when there are any.
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
