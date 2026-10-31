#if os(iOS)
import SwiftUI
import CabalmailKit

/// The list's panel below a laptop fold (#1649): the split's list, with its
/// bar, in a navigation stack of its own across the window's width, between
/// the crease and the reader's own action bar (`LaptopPanelPolicy`). The bar
/// carries the folder button and Settings, the folder's name with its switch
/// menu, Compose, More and the addresses `@`, and the row under it Filter,
/// Sort and Select; the folder button opens the split's floating folder
/// panel, which then starts below the fold too.
///
/// The `@` turns the panel into the address list (New, the filter and
/// Refresh), down to the window's bottom edge, while a cover hides the
/// message above (`LaptopAddressesPolicy`); `@` again, or a message or a
/// list opened, brings the list back.
///
/// The search field shows only while a search is engaged, so the list keeps
/// its rows: the spec's panel header has no search field, which it gives
/// the Search tab of the one-tree layout instead.
///
/// The list moves here from the split's list column, which is hidden and
/// holds no list meanwhile, and back again on leaving laptop pose. Each way
/// a mail list takes the window's selection, checked rows and highlight
/// included, and its place (`SceneNavigator.listMoves()`), and a feed list
/// takes the moved list's model and top row (`FeedListHold`), so either
/// opens where the other was. Giving the panel to the address list and back
/// is the same move.
struct LaptopListPanel: View {
    let mail: WideMail
    /// Opens the split's floating folder panel.
    let showFolders: () -> Void
    /// The panel's `@`: the address list in the list's place, or the list
    /// back.
    let toggleAddresses: () -> Void
    /// This main window's commands, so the gear opens Settings in this
    /// window rather than in every one (`WindowCommands`).
    @Environment(\.windowCommands) private var windowCommands

    var body: some View {
        NavigationStack {
            panelContent
                .toolbar(removing: .sidebarToggle)
                // Ranked as the open inspector's toggle while the address
                // list shows: it is then the way back to the list.
                .toolbar {
                    AddressInspectorToolbarItem(
                        addressInspectorPresented: mail.laptopPanelShowsAddresses, toggle: toggleAddresses
                    )
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
                    // The spec's panel header carries Settings, which the
                    // folder panel's gear otherwise holds out of reach
                    // behind the folder button.
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            windowCommands?.send(.settings)
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("laptopPanel.settings")
                    }
                }
        }
        .overlay(alignment: .top) { Divider() }
    }

    /// The list, or the address list in its place, with the inspector's own
    /// header row and filter.
    @ViewBuilder
    private var panelContent: some View {
        if mail.laptopPanelShowsAddresses {
            AddressListView(externalFilter: mail.$state.addressListFilter)
                .inlineNavigationTitle()
        } else {
            mail.content(header: { searchHeader })
        }
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

extension View {
    /// The laptop panel's address list's ties to the rest of the window
    /// (`LaptopAddressesLifecycle`).
    func laptopAddressesLifecycle(_ mail: WideMail, feedListHold: FeedListHold) -> some View {
        modifier(LaptopAddressesLifecycle(mail: mail, feedListHold: feedListHold))
    }
}

/// What the laptop panel's address list owes the window while no list is
/// mounted beside the reader (`LaptopAddressesPolicy`): a message parked for
/// the list ends it, a feed list's hand-off nobody took is let go once the
/// window leaves its scope, and the open message goes if another window or
/// the composer removes it (`CoveredMessageWatch`).
private struct LaptopAddressesLifecycle: ViewModifier {
    let mail: WideMail
    let feedListHold: FeedListHold
    @Environment(AppState.self) private var appState
    @State private var watch = CoveredMessageWatch()

    func body(content: Content) -> some View {
        content
            // A tapped notification, the resume banner, a Spotlight result
            // or a rebuilt tree's open message: parked for the list, which
            // opens it only once it is back to select it.
            .onChange(of: mail.navigator.restores.pendingRestore) { _, restore in
                if restore != nil { mail.endLaptopPanelAddresses() }
            }
            // The address list took the moved feed list's place and the
            // window went on to another list (`FeedListHold`).
            .onChange(of: mail.selectedFeedScope) {
                feedListHold.releaseUntakenHandOff()
            }
            .onChange(of: coveredMessage, initial: true) { _, ref in
                watch.watched = ref
            }
            .task {
                let mail = mail
                watch.dropOpenMessage = {
                    mail.navigator.selectMessage(nil, isSearching: mail.isSearching, from: mail.tree)
                }
                appState.mailStore.events.subscribe(watch)
            }
    }

    /// The open message, while the address list covers the reader.
    private var coveredMessage: MessageRef? {
        guard mail.laptopPanelShowsAddresses, let envelope = mail.selectedEnvelope else { return nil }
        return envelope.ref(defaultFolder: mail.selectedFolder?.path ?? "")
    }
}

/// What covers the message above a laptop fold while the panel shows the
/// address list (`LaptopAddressesPolicy`): opaque, with nothing to tap, from
/// the split's top (and the status bar's strip above it) to the crease's
/// bottom edge. The reader stays mounted underneath, so the list coming
/// back shows it as it was, without rebuilding its web view.
///
/// It reports nothing to the laptop slot, unlike the reader's placeholders
/// (`LaptopFoldClearance`): the panel's bottom is the split's while it
/// shows.
struct LaptopAddressesCover: View {
    /// From the split's top to the crease's bottom edge.
    let height: CGFloat
    /// The crease's own height, which the prompt stays above.
    let foldHeight: CGFloat

    var body: some View {
        ContentUnavailableView {
            Label("Addresses", systemImage: "at")
        } description: {
            Text("Tap an address to copy it.")
        }
        .padding(.bottom, foldHeight)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background {
            Rectangle().fill(.background).ignoresSafeArea(edges: .top)
        }
    }
}
#endif
