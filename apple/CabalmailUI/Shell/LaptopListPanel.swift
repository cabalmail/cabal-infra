#if os(iOS)
import SwiftUI

/// The list's panel below a laptop fold (#1649): the split's list, with its
/// bar, in a navigation stack of its own across the window's width, between
/// the crease and the reader's own action bar (`LaptopPanelPolicy`). The bar
/// carries the folder button, the folder's name with its switch menu,
/// Compose and More, and the row under it Filter, Sort and Select; the
/// folder button opens the split's floating folder panel, which then starts
/// below the fold too, with Settings on its bar.
///
/// The search field shows only while a search is engaged, so the list keeps
/// its rows: the spec's panel header has no search field, which it gives
/// the Search tab of the one-tree layout instead.
///
/// The list moves here from the split's list column, which is hidden and
/// holds no list meanwhile, and back again on leaving laptop pose; each way
/// the window hands it its selection, checked rows and highlight included,
/// and its place (`SceneNavigator.listMoves()`), so it opens where the other
/// list was.
struct LaptopListPanel: View {
    let mail: WideMail
    /// Opens the split's floating folder panel.
    let showFolders: () -> Void

    var body: some View {
        NavigationStack {
            mail.content(header: { searchHeader })
                .toolbar(removing: .sidebarToggle)
                // The addresses inspector's one way in on the wide shells,
                // which the hidden list column's bar can't offer (#1626).
                .toolbar {
                    mail.addressInspectorToolbarItem
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: showFolders) {
                            // Titled for the system overflow's rows (#1787),
                            // as the list column's folder button is.
                            Label("Folders", systemImage: "sidebar.leading")
                        }
                        .accessibilityIdentifier("laptopPanel.folders")
                    }
                }
        }
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var searchHeader: some View {
        if mail.isSearching {
            mail.searchField
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
    }
}
#endif
