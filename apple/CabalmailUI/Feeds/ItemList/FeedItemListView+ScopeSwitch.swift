import SwiftUI
import CabalmailKit

// The scope-switch menu: the scope name at the top of the feed item list is
// a tappable affordance that opens the other feeds and folders, exactly as
// the folder name above the mail list opens the other folders
// (`MessageListView+FolderSwitch`, whose notes on each platform apply here
// unchanged). Pulled into a sibling extension so the primary
// FeedItemListView body stays under SwiftLint's `type_body_length` cap.
//
// On iOS, iPadOS and visionOS the menu is the system's own title menu
// (`toolbarTitleMenu`). macOS never materializes one for a column title, so
// the Mac removes the toolbar's title text and puts a `Menu` in the same
// slot — a `.navigation` toolbar item with the bold name and a chevron,
// borderless or macOS 27 drops the label (#1601). The rows are `Toggle`s so
// the scope in effect carries the native mark an assistive client reads
// (#1367), and the menu's identity carries what the rows draw (#1329,
// #1337). The feed list has no search scope — its search is a field inside a
// single feed's list — so the menu is always on.
extension FeedItemListView {
    /// The menu's rows for the catalog loaded so far, with the current scope
    /// checked.
    var scopeSwitchRows: [ReaderMenuRow<RssItemScope>] {
        FeedScopeSwitchMenuPolicy.rows(
            folders: folders, subscriptions: switchSubscriptions, current: scope, currentTitle: title
        )
    }

    /// Hangs the scope menu on `content`'s title.
    @ViewBuilder
    func feedScopeSwitchTitle<Content: View>(_ content: Content) -> some View {
        #if os(macOS)
        content
            .toolbar(removing: .title)
            .toolbar {
                // Detached from macOS 26's shared glass background, as the
                // mail list's menu is: the item stands in for bare title
                // text, not for a bordered control.
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { scopeSwitchMenu }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { scopeSwitchMenu }
                }
            }
        #else
        content.toolbarTitleMenu { scopeSwitchMenuItems }
        #endif
    }

    #if os(macOS)
    /// macOS: the scope name, bold like the toolbar title it stands in for,
    /// as a menu with the system's pull-down chevron.
    @ViewBuilder
    var scopeSwitchMenu: some View {
        let rows = scopeSwitchRows
        Menu {
            scopeSwitchMenuItems
        } label: {
            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        // Both halves, or macOS 27 draws a 36x36 chevron and no name (#1601).
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Feed scope, \(title)")
        .accessibilityHint("Switch feed or folder")
        .accessibilityIdentifier("feed.scopeSwitch")
        // The global search field shares this toolbar section and is sized
        // to what the menu leaves it (`ToolbarSearchFieldWidth`); only the
        // item knows how wide the name came out.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onScopeMenuWidthChanged(width)
        }
        // macOS keeps the AppKit menu it built the first time this `Menu`
        // was opened — checkmarks and row titles included — so the identity
        // carries what the rows draw (#1337, same mechanism as #1329).
        .id(FeedScopeSwitchMenuPolicy.identity(rows))
    }
    #endif

    /// The menu body: All Feeds, then the flattened tree.
    @ViewBuilder
    var scopeSwitchMenuItems: some View {
        ForEach(scopeSwitchRows) { row in
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in
                    // Re-picking the scope the list is on is a no-op: the
                    // parent would only re-key the same view.
                    guard !row.isOn else { return }
                    onSwitchScope(row.option)
                }
            )) {
                Label(row.label, systemImage: FeedScopeSwitchMenuPolicy.symbol(for: row.option))
            }
        }
    }
}
