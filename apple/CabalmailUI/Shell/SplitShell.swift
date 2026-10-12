#if os(iOS)
import SwiftUI
import CabalmailKit

/// The iPad split's shell, also iPhone Duo's inner display: a message list
/// beside the reader, with the folder list in a floating panel.
///
/// What the columns show is shared with the Mac window (`WideMail`, and the
/// columns in `Shell/Columns/`). This shell owns the split's chrome:
///
/// - The split view's own sidebar column is pinned collapsed at zero width.
///   Revealing folders floats `folderPanelOverlay` OVER the message list
///   instead, so the list never moves and its leading swipe (read/unread)
///   keeps its normal drag distance. (When the sidebar tiled to the list's
///   left, `twoBesideSecondary`, the split view's interactive column gesture
///   out-arbitrated the row's leading swipe; and UIKit's `.overlay` split
///   behavior still composes the sidebar BESIDE the supplementary column, so
///   it, too, would shove the list rightward.)
/// - The list column is pinned to a persisted width with a drag handle on
///   its trailing edge, and the reader declares its floor to UIKit (#1679).
/// - The global search field sits in a header row inside the list column:
///   the column's own navigation bar has no room for it
///   (`GlobalSearchFieldPlacement`).
/// - Settings is a sheet, presented from the window's tab state so it
///   survives a fold (`SettingsSheetPresenter`); the folder panel's gear and
///   ⌘, both open it.
///
/// A fold or a narrowing swaps this shell for the tabs (`TabShell`), so the
/// folder panel and the addresses inspector close with it (#1663, #1692);
/// the window's folder, message, search and tab are the navigator's and
/// carry across.
struct SplitShell: View {
    @Environment(SceneNavigator.self) private var navigator
    /// This main window's commands, so the folder panel's Settings gear opens
    /// Settings in this window rather than in every one (`WindowCommands`).
    @Environment(\.windowCommands) private var windowCommands
    @State private var mailState = WideMailState()
    @FocusState private var searchFieldFocused: Bool
    /// Whether the floating folder panel is showing. The panel replaces the
    /// split view's own sidebar reveal — see `folderPanelOverlay`. Starts
    /// hidden every launch, like the collapsed sidebar it replaced.
    @State private var folderPanelPresented = false
    /// Live width of the content (message list) column.
    @State private var contentColumnWidth: CGFloat = 0
    /// Persisted width of the message-list (content) column.
    /// `NavigationSplitView` doesn't report where a user drags the native
    /// list-reader divider, so the column is pinned to this width and a
    /// `ColumnResizeHandle` on its trailing edge drives it — letting the
    /// chosen split survive cold launches. Stored as `Double` because
    /// `@AppStorage` has no `CGFloat` overload.
    @AppStorage("cabalmail.layout.listColumnWidth") private var listColumnWidthStored: Double = 360

    private var mail: WideMail {
        WideMail(
            navigator: navigator,
            state: $mailState,
            searchFieldFocus: $searchFieldFocused,
            dismissFolderPanel: dismissFolderPanel
        )
    }

    var body: some View {
        let mail = self.mail
        NavigationSplitView(
            columnVisibility: .constant(.doubleColumn),
            preferredCompactColumn: mail.compactColumnSelection
        ) {
            // The folder list lives in the floating panel
            // (`folderPanelOverlay`), not in this column, which stays empty
            // and permanently collapsed. Removing the system sidebar toggle
            // keeps the content toolbar from offering to reveal the empty
            // column — the custom button in `listColumn` drives the panel
            // instead. The zero column width matters: the pinned
            // `.doubleColumn` only holds until a rotation or window resize,
            // when UIKit's split controller re-expands the sidebar on its
            // own and the constant binding can't push back — tiling this
            // column in as a blank leading pane. At width 0 the re-expanded
            // column has no footprint, so the pane can never appear.
            Color.clear
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(0)
        } content: {
            listColumn(mail)
        } detail: {
            // The reader's floor, declared where UIKit reads it. Without it
            // the split controller applies its own secondary-column minimum
            // (about 540 pt, measured on iOS 27.1) and, when the list leaves
            // less than that, gives up tiling and floats the list over a
            // reader the width of the whole window: on iPhone Duo's 951 pt
            // inner display a list wider than 410 pt did that, so the
            // crease-pinned 50/50 split could never tile (#1679). The floor
            // is the one `listColumnBounds` already keeps for the reader.
            mail.reader(mailPlaceholder: EmptyModifier(), feedPlaceholder: EmptyModifier())
                .navigationSplitViewColumnWidth(min: readerColumnMinWidth, ideal: readerColumnMinWidth)
        }
        // Revealing folders floats a panel OVER the message list rather than
        // tiling the split's sidebar column, so the list never shifts and its
        // leading swipe geometry is undisturbed. The explicit `.leading`
        // alignment matters: while the panel is closed the scrim is absent,
        // the ZStack shrinks to the panel's own size, and a default
        // (centered) overlay would park the slid-out panel half on screen
        // instead of fully off the leading edge.
        .overlay(alignment: .leading) {
            folderPanelOverlay
        }
        .wideMailBehaviour(mail)
        .settingsSheetPresenter()
    }

    /// Column-header host for the search field, where the list column's own
    /// navigation bar has no room for it (`GlobalSearchFieldPlacement`). Takes
    /// the column's full width, so the magnifier and the whole placeholder
    /// are drawn whatever the column is dragged to, and sits above the list's
    /// filter pills — the same place the folder panel's filter field sits
    /// over its list.
    private func columnHeaderSearchField(_ mail: WideMail) -> some View {
        mail.searchField
            .padding(.horizontal)
            .padding(.top, 4)
            .padding(.bottom, 6)
    }

    /// The list column: the shared content with the search field in its
    /// header, the column's bar, and the pinned width with its drag handle.
    private func listColumn(_ mail: WideMail) -> some View {
        mail.content(header: { columnHeaderSearchField(mail) })
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                recordContentColumnWidth(newWidth)
            }
            // The system sidebar toggle is removed on the sidebar column
            // above, which is where iPadOS 26 hosts it. iOS 27 on a
            // phone-idiom host (iPhone Duo's inner display) hosts it on this
            // column instead, so the list's bar carried two sidebar icons:
            // the system one, which only revealed the zero-width column and
            // its dimming scrim, next to the folder-panel toggle that stands
            // in for it (#1690).
            .toolbar(removing: .sidebarToggle)
            // The toggle for the trailing addresses inspector. Search and
            // the folder switch are in the column's content, not this bar.
            .toolbar {
                mail.addressInspectorToolbarItem
            }
            // Folder-panel toggle, standing in for the removed system sidebar
            // toggle in the same leading slot.
            //
            // The app-level Settings gear used to sit beside it and does not
            // any more: five occupants overflow this column's bar on iPadOS
            // 27, and the system overflow they fold into never presents,
            // which took Compose and Addresses out of reach entirely (#1626).
            // The gear is the occupant that belongs least here now that the
            // folder list is a floating panel — it is app-level chrome, not
            // message-list chrome — so it moved onto that panel
            // (`folderPanelOverlay`). Cmd+, still reaches Settings from
            // anywhere (`CabalmailApp`'s `.appSettings` command group).
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(folderPanelAnimation) {
                            folderPanelPresented.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .accessibilityLabel("Toggle folder list")
                    }
                }
            }
            // Pin the list column to its persisted width and hang the drag
            // handle on its trailing edge.
            .navigationSplitViewColumnWidth(listColumnWidth)
            .overlay(alignment: .trailing) {
                ColumnResizeHandle(
                    width: listColumnWidthBinding,
                    minWidth: listColumnBounds.minimum,
                    maxWidth: listColumnBounds.maximum
                )
            }
    }

    /// Records the measured content-column width, as the wide layouts have
    /// since the search field first rode the column's bar (#1047). iPadOS
    /// draws that field in the column's header instead, so nothing on this
    /// shell reads the width today; the write moved here with the split
    /// unchanged.
    private func recordContentColumnWidth(_ width: CGFloat) {
        contentColumnWidth = width
    }
}

// MARK: - Floating folder panel

/// The floating folder panel that replaces the split view's own sidebar
/// reveal.
///
/// SwiftUI's `NavigationSplitView` exposes no knob that reveals the sidebar
/// over an unmoving content column: tiling and displacing both shove the
/// message list rightward, and even UIKit's `.overlay` split behavior (the
/// previous attempt here, `SplitOverlayConfigurator`) composes the sidebar
/// BESIDE the supplementary column over the detail — the list still moves. So
/// the split's sidebar column is pinned collapsed and the folder list floats
/// here instead: a fixed-width panel slid in from the leading edge over the
/// list, with a dimming scrim that dismisses on tap.
///
/// The panel stays MOUNTED while closed (slid offscreen, not removed) so
/// `FolderListView` loads folders at launch and drives the INBOX landing /
/// resume toast (`onFoldersLoaded`) exactly as the hidden sidebar column used
/// to — and so its drop targets are live the moment the panel opens mid-drag.
extension SplitShell {
    /// Slide/scrim animation, shared by the toolbar toggle and the
    /// folder-pick auto-dismiss so every path moves the panel the same way.
    private var folderPanelAnimation: Animation { .snappy(duration: 0.28) }

    /// Fixed panel width, matching the split view's own sidebar column.
    private var folderPanelWidth: CGFloat { 320 }

    @ViewBuilder
    var folderPanelOverlay: some View {
        ZStack(alignment: .leading) {
            if folderPanelPresented {
                Color.black.opacity(0.15)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(folderPanelAnimation) { folderPanelPresented = false }
                    }
                    .transition(.opacity)
                    .accessibilityLabel("Dismiss folder list")
                    .accessibilityAddTraits(.isButton)
            }
            // Its own NavigationStack: the sidebar hangs a navigation title
            // (the Cabalmail mark stands in for it), which needs a navigation
            // container now that the view no longer lives in the split's
            // sidebar column.
            NavigationStack {
                mail.sidebar(titleMarkSize: 102, header: { EmptyView() })
                    // Settings, evicted from the message-list column's bar
                    // where a fifth occupant overflowed it on iPadOS 27
                    // (#1626). This panel is the iPad's app-level chrome —
                    // the analogue of macOS's Settings scene and compact
                    // iPhone's Settings tab — and it has a bar of its own
                    // with one occupant.
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                windowCommands?.send(.settings)
                            } label: {
                                Image(systemName: "gearshape")
                                    .accessibilityLabel("Settings")
                            }
                            .accessibilityIdentifier("folderPanel.settings")
                        }
                    }
            }
                .frame(width: folderPanelWidth)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.25), radius: 18, x: 4, y: 0)
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .offset(x: folderPanelPresented ? 0 : -(folderPanelWidth + 60))
                .accessibilityHidden(!folderPanelPresented)
        }
        .animation(folderPanelAnimation, value: folderPanelPresented)
    }

    /// Slide the folder panel away after a pick, so the message list is
    /// fully interactive again. One routine for the sidebar binding (a user
    /// pick) and the folder-change handler (a programmatic one); a no-op on
    /// launches, where INBOX auto-selects with the panel already closed.
    private func dismissFolderPanel() {
        withAnimation(folderPanelAnimation) { folderPanelPresented = false }
    }
}

// MARK: - Resizable list column

/// Clamp bounds for the resizable message-list column. Shared with the Mac's
/// width policy so the two can't drift — see `ListColumnWidth`.
private let listColumnMinWidth = ListColumnWidth.minimum
/// Width reserved for the reading pane when clamping the list column's maximum.
private let readerColumnMinWidth = ListColumnWidth.readerFloor

extension SplitShell {
    /// Clamp range for the pinned list column: a ceiling that leaves the
    /// reading pane its floor and a little more (`ListColumnWidth.pinnedBounds`
    /// — an exact fit is what #1716 was), and a floor that follows it down in a
    /// window too narrow to seat both. Falls back to a generous cap until the
    /// first geometry read lands.
    private var listColumnBounds: (minimum: CGFloat, maximum: CGFloat) {
        guard mailState.splitWidth > 0 else { return (listColumnMinWidth, 640) }
        return ListColumnWidth.pinnedBounds(splitWidth: mailState.splitWidth)
    }

    /// The persisted list-column width, clamped to the current valid range.
    private var listColumnWidth: CGFloat {
        let bounds = listColumnBounds
        return min(max(CGFloat(listColumnWidthStored), bounds.minimum), bounds.maximum)
    }

    /// Binding the drag handle writes: clamps on read, persists on write.
    private var listColumnWidthBinding: Binding<CGFloat> {
        Binding(
            get: { listColumnWidth },
            set: { listColumnWidthStored = Double($0) }
        )
    }
}
#endif
