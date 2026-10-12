#if os(iOS) || os(macOS)
import SwiftUI
import CabalmailKit

// What the two wide shells share: `DesktopShell` (the Mac window) and
// `SplitShell` (the iPad split). Each writes its own `NavigationSplitView`
// and owns its own chrome; the window's mail tree, its search, its feeds and
// its addresses inspector behave the same in both, and live here.
//
// iOS and macOS only: the addresses inspector is unavailable on visionOS,
// whose shell (`OrnamentShell`) has no wide split.

/// A wide shell's own state for its mail tree, held in one `@State`, so a
/// change re-renders the shell as a whole.
struct WideMailState {
    /// The shell's identity as one of the window's trees. The navigator
    /// shows a tree the open message only once it has appeared, and ignores
    /// writes from a tree a layout swap is tearing down (`SceneNavigator`).
    var tree = UUID()
    /// How many messages the list has selected, reported by
    /// `MessageListView`. Drives the reader's "N Messages Selected".
    var listSelectionCount = 0
    /// The addresses inspector: whether it is showing, and whether the `@`
    /// button asked for that — the framework may only close the inspector,
    /// never open it (`InspectorPresentationPolicy`, #1663). Hidden on every
    /// launch: it is an occasional reference panel, so it doesn't persist
    /// open, and a fold closes it.
    var inspector = InspectorPresentationPolicy.State(presented: false, requested: false)
    /// The window's search model (`SceneNavigator.searchModel`), held here so
    /// the search field and the content column share one query and result
    /// set. The tab layout's Search tab takes the same model.
    var searchModel: MessageListViewModel?
    /// The sidebar's "Filter folders" text. The shell renders the field in
    /// the list's own header so it sits under the global search rather than
    /// being hoisted above it by `.searchable(placement: .sidebar)`.
    var folderListFilter = ""
    /// The inspector's "Filter addresses" text.
    var addressListFilter = ""
    /// Live width of the whole split view, which the list column's bounds
    /// leave the reader's floor out of (`ListColumnWidth`).
    var splitWidth: CGFloat = 0
}

/// The wide shells' shared rules, built on each render from the shell's
/// state: what the columns show, the bindings that carry a pick (#1217), and
/// the column views themselves.
@MainActor
struct WideMail {
    let navigator: SceneNavigator
    @Binding var state: WideMailState
    /// Focus on the global search field. While the field is focused, holds a
    /// query or has run a search, the content column shows its results.
    let searchFieldFocus: FocusState<Bool>.Binding
    /// Slides the split's folder panel away; nothing on the desktop, whose
    /// sidebar is tiled.
    let dismissFolderPanel: () -> Void

    var tree: UUID { state.tree }
    var selectedFolder: Folder? { navigator.folder(in: tree) }
    var selectedEnvelope: Envelope? { navigator.envelope(in: tree) }
    var listSelectionCount: Int { state.listSelectionCount }
    var addressInspectorPresented: Bool { state.inspector.presented }
    var splitWidth: CGFloat { state.splitWidth }

    /// The split's feed list (RSS plan, phase 5): the window's, while it is
    /// in the feeds section (`SceneNavigator.splitShowsFeeds`), and mutually
    /// exclusive with the mail folder there.
    var selectedFeedScope: RssItemScope? {
        navigator.splitShowsFeeds ? navigator.feeds.scope(in: tree) : nil
    }

    var selectedFeedItem: RssItem? {
        selectedFeedScope == nil ? nil : navigator.feeds.item(in: tree)
    }

    /// Whether the content column should show search results rather than the
    /// selected folder: the search field is focused, holds a query, or a
    /// search is currently active.
    var isSearching: Bool {
        guard let model = state.searchModel else { return false }
        return searchFieldFocus.wrappedValue || !model.searchQuery.isEmpty || model.isSearchActive
    }

    // MARK: Bindings

    /// Which column a collapsed split shows (`SceneNavigator.setCompactColumn`).
    /// The wide shells tile their columns, so this only matters while UIKit
    /// floats the list over the reader.
    var compactColumnSelection: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { navigator.compactColumn(in: tree) },
            set: { navigator.setCompactColumn($0, isSearching: isSearching, from: tree) }
        )
    }

    /// The list's selection, through the navigator, which records it.
    var envelopeSelection: Binding<Envelope?> {
        Binding(
            get: { selectedEnvelope },
            set: { navigator.selectMessage($0, isSearching: isSearching, from: tree) }
        )
    }

    /// The sidebar's selection, with the search dismissal on the write
    /// (#1217).
    ///
    /// It rides the *binding* rather than `onChange(of: selectedFolder)`
    /// because `onChange` only sees a value that changed. Re-picking the
    /// folder that was already selected when the search started — the
    /// report's second, feedback-free variant, where not even the panel
    /// dismisses — writes the same `Folder` back, which a binding setter sees
    /// and an `onChange` does not.
    var sidebarSelection: Binding<Folder?> {
        Binding(
            get: { selectedFolder },
            set: { picked in
                if ContentColumnPolicy.pickEndsSearch(isSearching: isSearching, picked: picked?.path) {
                    endGlobalSearch()
                }
                // Same reason the dismissal is here: re-picking the selected
                // folder leaves the panel up otherwise, which is the half of
                // #1217 where the tap produced no feedback at all.
                if picked != nil { dismissFolderPanel() }
                navigator.selectFolder(picked)
            }
        )
    }

    /// The Feeds section's selection: a pick clears the mail selection so the
    /// content and detail columns swap to the item list and reader; a mail
    /// folder pick (`sidebarSelection`) clears this in turn.
    var feedSidebarSelection: Binding<RssItemScope?> {
        Binding(
            get: { selectedFeedScope },
            set: { picked in
                if picked != nil { feedListOpened(endingSearch: true) }
                navigator.showFeeds(picked)
            }
        )
    }

    /// The item list's selection, through the navigator.
    var feedItemSelection: Binding<RssItem?> {
        Binding(get: { selectedFeedItem }, set: { navigator.selectFeedItem($0, from: tree) })
    }

    /// The binding `.inspector(isPresented:)` drives, filtered through
    /// `InspectorPresentationPolicy` so a framework-initiated present (the
    /// iPhone Duo unfold, #1663) is dropped while a dismiss is honoured.
    var addressInspectorBinding: Binding<Bool> {
        Binding(
            get: { state.inspector.presented },
            set: { incoming in
                applyInspector(InspectorPresentationPolicy.framework(wrote: incoming, to: state.inspector))
            }
        )
    }

    // MARK: Actions

    /// The view's half of opening a feed list: the folder panel closes and
    /// the mail multi-selection goes. A pick or a tapped feed banner also
    /// ends a search, as the search field's × does; a landing or a layout
    /// swap's hand-off leaves it on screen (#1654).
    func feedListOpened(endingSearch: Bool) {
        if endingSearch, isSearching { endGlobalSearch() }
        dismissFolderPanel()
        setListSelectionCount(0)
    }

    /// End the global search exactly the way the search field's own × does
    /// (`GlobalSearchField`): zero the query and drop focus, and let the
    /// mounted search list's `onChange(of: searchQuery)` call `clearSearch()`
    /// from there. One routine rather than a second copy of the rule — the ×
    /// path already lands the user back on a folder, which is what the folder
    /// pick wanted all along.
    func endGlobalSearch() {
        let model = state.searchModel
        model?.searchQuery = ""
        searchFieldFocus.wrappedValue = false
    }

    /// The `@` button: opens and closes the addresses inspector through
    /// `InspectorPresentationPolicy`, so the button's request is what the
    /// framework's own writes are checked against.
    func toggleAddressInspector() {
        applyInspector(InspectorPresentationPolicy.toggled(state.inspector))
    }

    private func applyInspector(_ inspector: InspectorPresentationPolicy.State) {
        if state.inspector != inspector { state.inspector = inspector }
    }

    func setListSelectionCount(_ count: Int) {
        if state.listSelectionCount != count { state.listSelectionCount = count }
    }

    // MARK: Columns

    /// The sidebar: the folder list with the feeds section, filtered by the
    /// shell's own field. The header and the title mark are the shell's.
    func sidebar<Header: View>(
        titleMarkSize: CGFloat?, @ViewBuilder header: @escaping () -> Header
    ) -> MailSidebarColumn<Header> {
        MailSidebarColumn(
            selection: sidebarSelection,
            filter: $state.folderListFilter,
            feedSelection: feedSidebarSelection,
            titleMarkSize: titleMarkSize,
            // The first load finishes the window's launch landing, or swaps
            // the fetched folder in for a stand-in
            // (`SceneNavigator.foldersLoaded`).
            onFoldersLoaded: { navigator.foldersLoaded($0) },
            header: header
        )
    }

    /// The content column: the feed list, the search results or the folder's
    /// messages. The header is where a shell hosts its search field.
    func content<Header: View>(
        onLeadingToolbarWidthChanged: @escaping (CGFloat) -> Void = { _ in },
        @ViewBuilder header: @escaping () -> Header
    ) -> MailContentColumn<Header> {
        MailContentColumn(
            feedList: selectedFeedScope.map {
                FeedListSelection(
                    scope: $0,
                    selection: feedItemSelection,
                    // A pick from the list's scope-switch menu goes through
                    // the same binding as a sidebar tap, so it clears the mail
                    // selection and records the resume session the same way.
                    onSwitchScope: { feedSidebarSelection.wrappedValue = $0 }
                )
            },
            search: state.searchModel,
            isSearching: isSearching,
            folder: selectedFolder,
            selection: envelopeSelection,
            onSelectionCountChanged: { setListSelectionCount($0) },
            // A pick from the list's folder-switch menu goes through the
            // same binding as a sidebar tap, so it ends a global search and
            // dismisses the split's folder panel the same way.
            onSwitchFolder: { sidebarSelection.wrappedValue = $0 },
            onLeadingToolbarWidthChanged: onLeadingToolbarWidthChanged,
            header: header
        )
    }

    /// The reader: the feed reader while a feed scope is selected, else the
    /// mail reader, the multi-selection count or the empty prompt. The
    /// placeholders' chrome is the shell's.
    func reader<MailChrome: ViewModifier, FeedChrome: ViewModifier>(
        mailPlaceholder: MailChrome, feedPlaceholder: FeedChrome
    ) -> some View {
        Group {
            if selectedFeedScope != nil, !isSearching {
                FeedReaderColumn(item: selectedFeedItem, placeholderChrome: feedPlaceholder)
            } else {
                MailReaderColumn(
                    selectionCount: listSelectionCount,
                    envelope: selectedEnvelope,
                    sidebarFolder: selectedFolder,
                    placeholderChrome: mailPlaceholder
                )
            }
        }
    }

    /// The search control itself, wired to the window's query and the shell's
    /// focus state (`GlobalSearchField`); each shell's host adds its own
    /// outer layout.
    var searchField: GlobalSearchField {
        let model = state.searchModel
        return GlobalSearchField(
            query: Binding(get: { model?.searchQuery ?? "" }, set: { model?.searchQuery = $0 }),
            isFocused: searchFieldFocus,
            onSubmit: { Task { await model?.runSearch() } }
        )
    }

    /// The `@` toggle for the content column's bar.
    var addressInspectorToolbarItem: AddressInspectorToolbarItem {
        AddressInspectorToolbarItem(
            addressInspectorPresented: addressInspectorPresented, toggle: toggleAddressInspector
        )
    }
}

/// The addresses inspector's `@` toggle, ranked for the bar it sits in.
///
/// While the inspector is open this is the one item the bar must keep: on an
/// iPhone Duo the column beside it is narrow enough that Compose and `@` both
/// fold into the system overflow, which is inert on the 27.1 beta, and the
/// inspector then cannot be closed (#1670).
///
/// Closed, it still ranks with Compose rather than below it: this button is
/// the *only* entry point to addresses on the wide shells (`SettingsSheet`'s
/// own doc records the move out of the sheet), so folding it away takes the
/// feature with it (#1626). What the overflow may take is the More menu,
/// whose Mark All as Read is also on the folder list's context menu and on
/// ⌥⌘T.
struct AddressInspectorToolbarItem: ToolbarContent {
    let addressInspectorPresented: Bool
    let toggle: () -> Void

    var body: some ToolbarContent {
        if addressInspectorPresented {
            ToolbarItem(placement: .primaryAction) { addressInspectorToggle }
                .keepsInBarFirst()
        } else {
            ToolbarItem(placement: .primaryAction) { addressInspectorToggle }
                .keepsInBar()
        }
    }

    private var addressInspectorToggle: some View {
        Button(action: toggle) {
            Image(systemName: "at")
                .accessibilityLabel("Addresses")
        }
    }
}

extension View {
    /// The wide shells' shared behaviour around their split: the menu
    /// reports, the split's width, the folder and feed hand-offs, the landing
    /// and the addresses inspector.
    func wideMailBehaviour(_ mail: WideMail) -> some View {
        modifier(WideMailReporting(mail: mail))
            .modifier(WideMailLifecycle(mail: mail))
    }
}

/// What the wide split tells the menus, and how wide it is.
private struct WideMailReporting: ViewModifier {
    let mail: WideMail

    func body(content: Content) -> some View {
        content
            // Keep the Message menu's commands validated against what they'd
            // actually act on (see `MessageMenuAvailability`).
            .reportsMessageMenuAvailability(
                selectedCount: mail.listSelectionCount,
                hasOpenMessage: mail.selectedEnvelope != nil
            )
            // The Feeds menu's twin, and which of the two sections is in
            // front, so the chords the Message/Mailbox and Feeds menus share
            // are never live on both (`SharedChordPolicy`). Only the wide
            // shells host feeds beside mail; on the tab layouts the Feeds tab
            // reports instead.
            .reportsFeedMenuAvailability(
                selectedCount: mail.selectedFeedItem == nil ? 0 : 1,
                hasOpenItem: mail.selectedFeedItem != nil,
                hasScope: mail.selectedFeedScope != nil && !mail.isSearching
            )
            .reportsActiveSection(mail.selectedFeedScope != nil && !mail.isSearching ? .feeds : .mail)
            // Track the split view's overall width so the list column's max
            // can be clamped to leave the reading pane a floor.
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                mail.state.splitWidth = newWidth
            }
    }
}

/// The wide split's hand-offs, its landing and its addresses inspector.
private struct WideMailLifecycle: ViewModifier {
    let mail: WideMail
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    func body(content: Content) -> some View {
        content
            // A folder change's view-side effects. The navigator has already
            // cleared the open message (so the detail column never renders an
            // old message against the new mailbox), moved the compact column
            // and recorded the folder; a same-path write is a metadata
            // reconcile and changes nothing here either.
            .onChange(of: mail.selectedFolder?.path) { _, path in
                mail.setListSelectionCount(0)
                // Search's "This folder only" narrows to the sidebar
                // selection (#1510), including programmatic writes that land
                // mid-search.
                let folder = mail.selectedFolder
                let model = mail.state.searchModel
                Task { await model?.setSearchAnchor(folder) }
                // Programmatic folder writes (Spotlight routing, a deep link,
                // the cursor restore) don't go through `sidebarSelection`, so
                // they still slide the panel away from here. A sidebar pick
                // has already done it and this is a no-op for it.
                if path != nil { mail.dismissFolderPanel() }
            }
            // A feed list opening without a pick (RSS plan, phase 5): a
            // landing or a hand-off, or a tapped feed banner, which ends a
            // search as a pick does.
            .onChange(of: mail.selectedFeedScope) { _, scope in
                if scope != nil { mail.feedListOpened(endingSearch: false) }
            }
            .onChange(of: mail.navigator.feedNavigations) {
                mail.feedListOpened(endingSearch: true)
            }
            // Catch-all drop target behind the whole split view: a message
            // released anywhere that isn't a folder row (the message list,
            // the reading pane, sidebar chrome) is refused. Folder rows are
            // nested, more-specific drop targets, so a real drop onto a
            // folder is handled there and never reaches this. Kept, though it
            // moves nothing, so a drag over the split looks as it always has.
            .dropDestination(for: MessageDragPayload.self) { _, _ in
                false
            }
            .task {
                // The window's launch landing — or, for a tree a layout swap
                // has just built, the window's route (`SceneNavigator`). A
                // wide tree may land in the feed reader instead.
                await mail.navigator.mailTreeAppeared(mail.tree, isWide: true)
                // The window's, shared with the tab layout's Search tab so a
                // layout swap keeps the query and results (#1654); this split
                // anchors it to the folder.
                if mail.state.searchModel == nil, let client = appState.client {
                    let model = mail.navigator.searchModel(
                        client: client, preferences: preferences, mailStore: appState.mailStore
                    )
                    model.searchAnchor = mail.selectedFolder
                    mail.state.searchModel = model
                }
            }
            // Addresses live in a trailing panel rather than the left
            // sidebar, keeping the sidebar free for folders and feeds. Hidden
            // by default; the bar's `@` button toggles it. Tapping an address
            // copies it to the pasteboard. `.inspector` is the native
            // trailing sidebar on iOS and macOS.
            .inspector(isPresented: mail.addressInspectorBinding) {
                AddressListView(externalFilter: mail.$state.addressListFilter)
                    .addressInspectorWidth(isPresented: mail.addressInspectorPresented)
            }
    }
}
#endif
