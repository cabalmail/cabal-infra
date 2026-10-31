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
/// - The list column is pinned to this window's width for the list it
///   shows, or to the fold while a vertical one crosses the window, with a
///   drag handle on its trailing edge (`ListColumnPolicy`), and the reader
///   declares its floor to UIKit (#1679).
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
    /// Whether the split view was first laid out too narrow to tile, and so
    /// has to be built again at the window's real width (#1988).
    @State private var retile = SplitRetilePolicy()
    /// This window's list width for each list the column shows, in points
    /// (0 is none), written only when a drag on the handle ends or a reset
    /// clears it (`ListColumnPolicy`, `ListColumnTab`).
    /// `NavigationSplitView` doesn't report where a user drags the native
    /// list-reader divider, so the column is pinned to this width and a
    /// `ColumnResizeHandle` on its trailing edge drives it.
    @SceneStorage(ListColumnTab.mail.sceneStorageKey) private var mailListWidth: Double = 0
    @SceneStorage(ListColumnTab.feeds.sceneStorageKey) private var feedsListWidth: Double = 0
    /// The drag in progress and the fold the list column has applied.
    @State private var columnState = ListColumnState()
    /// The split view's frame in the window, measured on the split itself,
    /// as `splitWidth` is.
    @State private var splitFrame: CGRect = .zero
    /// Whether the list is over the reader, in a window taller than wide
    /// (`ListOverlay`, #1686).
    @State private var listOverlay = ListOverlay()
    /// Whether the window is taller than wide, measured outside the
    /// addresses inspector (`ListColumnPolicy.windowIsTall`).
    @State private var windowIsTall = false
    /// The crease the reader keeps above while the split is arranged for
    /// laptop pose, and where the reader ends (`LaptopPanelPolicy`, #1649).
    @State private var laptopReader = LaptopReaderSlot()
    /// The feed list's state as it moves below a laptop fold and back
    /// (`FeedListHold`), as the window's navigator holds the mail list's.
    @State private var feedListHold = FeedListHold()
    @Environment(\.foldState) private var foldState
    @Environment(\.foldDivision) private var foldDivision
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            columnVisibility: listColumnVisibility,
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
            // is the one `ListColumnPolicy.bounds` already keeps for the reader —
            // and, in a split too narrow to seat that beside the pinned list,
            // what the split has left instead, because the two declared
            // together would over-subscribe it (#2106).
            //
            // In book pose the reader starts its content past the crease's
            // keep-out (`CreaseClearance`). Always present, at 0 with no fold,
            // so a fold reflows the web view and never rebuilds it.
            //
            // In laptop pose the reader ends its content above the fold, its
            // placeholders here and a message or an article inside its own
            // bar's inset, and
            // hides the navigation bar a stock split leaves on the upright
            // half (`LaptopPanelPolicy`). Values only, so a fold reflows the
            // web view and never rebuilds it.
            //
            // While the laptop panel's address list covers it, the reader
            // stays mounted, marked hidden from VoiceOver and disabled, so
            // nothing acts on a message the user can't see
            // (`LaptopAddressesPolicy`). Disabled as well: the hiding doesn't
            // reach its own bar or its web view, which the accessibility tree
            // still lists (Duo simulator, 2026-10-30).
            mail.reader(mailPlaceholder: LaptopFoldClearance(), feedPlaceholder: LaptopFoldClearance())
                .accessibilityHidden(mail.laptopPanelShowsAddresses)
                .disabled(mail.laptopPanelShowsAddresses)
                .padding(.leading, readerCreaseInset)
                .navigationSplitViewColumnWidth(min: readerColumnMinWidth, ideal: readerColumnMinWidth)
                .toolbar { messagesButton }
                .toolbar(laptopReader.crease == nil ? .automatic : .hidden, for: .navigationBar)
                .environment(\.laptopReader, laptopReader)
                .environment(\.readerFillsTallWindow, listOverlays)
        }
        // A message or a feed item opened over the floating list sends it
        // away; none open brings it back (`ListOverlay`).
        .onChange(of: openReading, initial: true) { _, opened in
            listOverlay.messageChanged(isOpen: opened != nil)
            // A message opened ends the laptop panel's addresses
            // (`LaptopAddressesPolicy`).
            if opened != nil { mail.endLaptopPanelAddresses() }
        }
        .laptopAddressesLifecycle(mail, feedListHold: feedListHold)
        // Laptop pose: the list in a panel below the fold, under the folder
        // panel, which floats over it as it does over the list column.
        .overlay(alignment: .top) {
            laptopPanel
        }
        .onChange(of: laptopCrease, initial: true) { old, crease in
            // Before the list moves, so the list mounting takes the window's
            // selection and place.
            if (old == nil) != (crease == nil) {
                // Unless the panel's address list is leaving: its list moved
                // when the address list took its place, and none is mounted
                // now to hand over.
                if crease != nil || !mail.laptopPanelShowsAddresses { listMoves() }
                // The addresses inspector would run up the upright half,
                // beside the message, so its list moves into the panel, and
                // back into the inspector on leaving laptop pose.
                mail.laptopArrangement(isArranged: crease != nil)
            }
            laptopReader.crease = crease
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
        // The split's own frame in the window, for the list column's width
        // and its place against the crease (`ListColumnPolicy`). Inside the
        // addresses inspector, at the depth `splitWidth` is measured, so it
        // leaves a tiled inspector out as that does. Read behind the split
        // with the keyboard's region ignored, so the docked keyboard coming
        // up for the search field cannot shorten it and change which floor
        // the column takes.
        .background {
            Color.clear
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    splitFrame = frame
                }
                .ignoresSafeArea(.keyboard)
        }
        // The fold the list column follows: pinned in book pose, and back to
        // the user's width on unfolding, in the divider's one animation.
        .onChange(of: foldState, initial: true) { _, fold in
            followFold(fold)
        }
        // The width every window shared before they kept their own.
        .task { ListColumnTab.retireAppWideWidth() }
        .environment(\.feedListHold, feedListHold)
        .wideMailBehaviour(mail)
        // The window's shape, outside the addresses inspector, which narrows
        // the split in a wide window without making it tall; with the
        // keyboard's region ignored, so a docked keyboard can't turn it.
        .background {
            Color.clear
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.height > proxy.size.width
                } action: { tall in
                    windowIsTall = tall
                }
                .ignoresSafeArea(.keyboard)
        }
        .settingsSheetPresenter()
        // Each width the split view is laid out at, which during a Zoom out
        // of compact is not the window's: UIKit lays the split out once at an
        // intermediate width (534 pt inside an 834 pt window, measured on
        // iPadOS 27), decides against tiling there, and keeps that decision
        // at full width. The new identity is what makes it decide again
        // (`SplitRetilePolicy`, #1988).
        //
        // `splitWidth` is the right reading and this is the only place that
        // has it: the narrow pass is the split view's own, and a geometry
        // reader hung outside the shell's modifiers — one modifier further
        // out than the reporting one that writes this — measures 834
        // throughout and never sees it.
        .onChange(of: mailState.splitWidth) { _, newWidth in
            let generation = retile.generation
            retile.recordLayout(width: newWidth)
            guard retile.generation != generation else { return }
            // The rebuilt split is a new tree of this window's, as a fold's
            // is: the navigator hands it the route — the folder, and the open
            // message parked for its list to reselect — and the list it
            // replaces cannot write while it is torn down (`TreeGate`).
            mailState.tree = UUID()
        }
        .id(retile.generation)
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
        columnList(mail)
            // In book pose the list's own controls (the search field, the
            // filter and sort rows, the rows' content) stop short of the
            // crease's keep-out (`CreaseClearance`); the bars' and rows'
            // backgrounds still reach the column's edge. 0 with no fold.
            .safeAreaPadding(.trailing, listCreaseClearance)
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
                        // Titled for the rows of the system overflow a
                        // squeezed bar folds it into, which draw the title
                        // (#1787); the bar itself draws the icon alone.
                        Label("Folders", systemImage: "sidebar.leading")
                    }
                    .accessibilityIdentifier("sidebar.leading")
                }
            }
            // Pin the list column to its width and hang the drag handle on
            // its trailing edge, where the column can move at all and no fold
            // holds it. The handle comes and goes with no transition of its
            // own, so an unfold's one animation is the width's.
            .navigationSplitViewColumnWidth(listColumnWidth)
            .overlay(alignment: .trailing) {
                let layout = listColumnLayout
                if layout.handleIsShown {
                    ColumnResizeHandle(
                        resetTitle: layout.canReset ? layout.resetTitle : nil,
                        onEvent: listColumnEvent
                    )
                    .transition(.identity)
                }
            }
            // In book pose the bar's trailing end sits within the crease's
            // keep-out, so its items move to the leading end beside Folders
            // (`ToolbarItemPlacement.listBar`). Read from the window's fold
            // as it is now, so the move never rides the divider's animation.
            .environment(\.listBarItemsLead, listCreaseClearance > 0)
    }

    /// The column's list, or nothing while the panel below a laptop fold
    /// holds it: one list at a time, handed the window's selection and place
    /// each way as it moves (`SceneNavigator.listMoves()`). The column is
    /// hidden meanwhile.
    @ViewBuilder
    private func columnList(_ mail: WideMail) -> some View {
        if laptopReader.crease == nil {
            mail.content(header: { columnHeaderSearchField(mail) })
        } else {
            Color.clear
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
                // Below a laptop fold, where the folders open over the list's
                // panel rather than across the upright half.
                .padding(.top, laptopPanelTop)
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

extension SplitShell {
    /// The list the column shows, for its width in this window. Search
    /// results take over whichever list that is, so search keeps its width.
    private var listColumnTab: ListColumnTab {
        mail.selectedFeedScope != nil ? .feeds : .mail
    }

    /// This window's stored width for the list the column shows; 0 is none.
    private var storedListWidth: Double {
        listColumnTab == .feeds ? feedsListWidth : mailListWidth
    }

    private func recordListWidth(_ width: Double) {
        switch listColumnTab {
        case .feeds: feedsListWidth = width
        case .mail, .search: mailListWidth = width
        }
    }

    /// The column's width, range and handle, from the split's frame, the fold
    /// and this window's width for the list it shows.
    private var listColumnLayout: ListColumnPolicy {
        ListColumnPolicy(
            split: splitFrame,
            fold: columnState.fold,
            division: foldDivision,
            stored: ListColumnPolicy.storedWidth(storedListWidth),
            live: columnState.liveWidth(for: listColumnTab),
            windowIsTall: windowIsTall
        )
    }

    private var listColumnWidth: CGFloat { listColumnLayout.width }

    /// The list column's trailing edge in the window, which is where the
    /// reader starts.
    private var listTrailingEdge: CGFloat { listColumnLayout.listLeadingEdge + listColumnWidth }

    /// How far the crease's keep-out reaches into the list column: the
    /// window's fold as it is now, against the edge the column is going to
    /// (`followFold` moves it to the band in the update after the fold
    /// arrives), so neither rides the divider's animation.
    private var listCreaseClearance: CGFloat {
        CreaseClearance.trailingClearance(fold: foldState, columnEndingAt: listTrailingEdge)
    }

    /// The reader's leading inset past the crease's keep-out.
    private var readerCreaseInset: CGFloat {
        CreaseClearance.leadingInset(fold: foldState, columnStartingAt: listTrailingEdge)
    }

    /// Floor the reading pane declares, which is `ListColumnWidth.readerFloor`
    /// wherever the split can seat it beside the pinned list column and the
    /// rest of the split where it cannot (`pinnedReaderFloor`). Constant, it
    /// over-subscribed every split narrower than 596pt — which is what the
    /// addresses inspector tiling beside the columns leaves on an iPad in
    /// portrait (#2106).
    private var readerColumnMinWidth: CGFloat { listColumnLayout.readerFloor }

    /// A drag moves the column as it goes and records its width when it
    /// ends; a cancelled one records nothing, and a reset clears the width
    /// in the divider's one animation.
    private func listColumnEvent(_ event: ColumnResizeEvent) {
        let layout = listColumnLayout
        let tab = listColumnTab
        switch event {
        case .began:
            columnState.beginDrag(tab: tab, from: layout.width)
        case .moved(let translation):
            columnState.moveDrag(tab: tab, translation: translation, bounds: layout.bounds)
        case .ended:
            if let width = columnState.endDrag(tab: tab) {
                recordListWidth(Double(width))
            }
        case .cancelled:
            columnState.cancelDrag()
        case .reset:
            columnState.cancelDrag()
            withAnimation(reduceMotion ? nil : ListColumnPolicy.dividerAnimation) {
                recordListWidth(0)
            }
        }
    }

    /// Applies the window's fold to the column: an unfold goes back to the
    /// user's width in the divider's one animation, and everything else
    /// moves the column with the window.
    private func followFold(_ fold: FoldState) {
        let animates = ListColumnPolicy.unfoldAnimates(
            from: columnState.fold, to: fold, division: foldDivision, reduceMotion: reduceMotion
        )
        withAnimation(animates ? ListColumnPolicy.dividerAnimation : nil) {
            columnState.follow(fold)
        }
    }
}

// MARK: - The list over the reader

extension SplitShell {
    /// Whether the list floats over a full-width reader: in a window taller
    /// than wide (`ListColumnPolicy.overlaysReader`).
    private var listOverlays: Bool { listColumnLayout.overlaysReader }

    /// What the reader has open, the section's message or feed item; nil for
    /// nothing. The feed item only while the reader shows it: a search in
    /// the Feeds section opens mail results (`WideMail.reader`). A message
    /// by its folder too, so a search result with another folder's UID is a
    /// new open.
    private var openReading: String? {
        if readerShowsFeeds { return mail.selectedFeedItem.map { "item:\($0.id)" } }
        return mail.selectedEnvelope.map { "message:\($0.folder ?? "")#\($0.uid)" }
    }

    /// Whether the reader shows the feed reader rather than mail, by the
    /// rule `WideMail.reader` draws it by.
    private var readerShowsFeeds: Bool {
        mail.selectedFeedScope != nil && !mail.isSearching
    }

    /// The split's columns. Tiled, both, always: the pinned `.doubleColumn`
    /// the zero-width sidebar relies on. Overlaid, the reader alone unless
    /// the list is shown, and a tap on the reader or a swipe that puts the
    /// list away is taken back from the split.
    ///
    /// In laptop pose the reader alone, whatever is open: the list is in the
    /// panel below the fold, and nothing the split asks brings it back.
    private var listColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { laptopReader.crease == nil ? listOverlay.visibility(overlays: listOverlays) : .detailOnly },
            set: { visibility in
                guard laptopReader.crease == nil else { return }
                listOverlay.splitAsked(for: visibility, overlays: listOverlays)
            }
        )
    }

    /// The reader's way back to the list while it floats away.
    @ToolbarContentBuilder
    private var messagesButton: some ToolbarContent {
        if listOverlay.offersMessagesButton(overlays: listOverlays) {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    withAnimation(.snappy(duration: 0.28)) { listOverlay.show() }
                } label: {
                    // A back button, as the spec draws it, rather than the
                    // folder panel's sidebar symbol.
                    Label(readerShowsFeeds ? "Articles" : "Messages", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("reader.showList")
            }
        }
    }
}

// MARK: - Laptop pose

extension SplitShell {
    /// The crease to arrange the split around: a laptop fold across a tall
    /// window, nil otherwise (`LaptopPanelPolicy`).
    private var laptopCrease: CGRect? {
        let arranged = LaptopPanelPolicy.isArranged(fold: foldState, windowIsTall: windowIsTall)
        return arranged ? foldState.crease : nil
    }

    /// The list moves between the column and the panel: the feed list
    /// through the split's own hold, a mail list through the window's
    /// (`SceneNavigator.listMoves`), each handing the list mounting next its
    /// state.
    private func listMoves() {
        if readerShowsFeeds {
            feedListHold.move()
        } else {
            navigator.listMoves(isSearching: mail.isSearching)
        }
    }

    /// How far below the split's top the panels start in laptop pose: the
    /// crease's bottom edge; 0 otherwise.
    private var laptopPanelTop: CGFloat {
        laptopReader.crease.map { max(0, $0.maxY - splitFrame.minY) } ?? 0
    }

    /// The list's panel, from the crease to the reader's own bar; with its
    /// address list, to the split's bottom, under a cover over the reader.
    @ViewBuilder
    private var laptopPanel: some View {
        if let crease = laptopReader.crease {
            let covered = mail.laptopPanelShowsAddresses
            let frame = LaptopPanelPolicy.panelFrame(
                split: splitFrame,
                crease: crease,
                readerBottom: LaptopAddressesPolicy.panelReaderBottom(laptopReader.readerBottom, covered: covered)
            )
            ZStack(alignment: .top) {
                if covered {
                    LaptopAddressesCover(height: frame.minY, foldHeight: crease.height)
                }
                LaptopListPanel(
                    mail: mail,
                    showFolders: { withAnimation(folderPanelAnimation) { folderPanelPresented = true } },
                    toggleAddresses: toggleLaptopPanelAddresses
                )
                .frame(width: frame.width, height: frame.height)
                .padding(.top, frame.minY)
            }
        }
    }

    /// The panel's `@`. The list leaving the panel hands its state to the
    /// one that comes back, as on a fold (`listMoves()`).
    private func toggleLaptopPanelAddresses() {
        if !mail.laptopPanelShowsAddresses { listMoves() }
        mail.toggleLaptopPanelAddresses()
    }
}
#endif
