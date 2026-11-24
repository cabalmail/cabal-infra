import SwiftUI
import CabalmailKit

/// The Flagged view's list (`docs/1.x/cross-media-ux-plan.md`, Phase 5):
/// flagged messages and flagged feed items together, newest first, each
/// drawn as its own medium's list draws it and opening in its own reader.
///
/// The selection is lifted to the host, as the folder and feed lists' is,
/// so each shell binds its reader to it. The model is the window's
/// (`SceneNavigator.flaggedList`), so this view can come and go (a reader
/// pushed over it on iPhone, a change of layout shell) without the rows
/// loading again.
struct FlaggedListView: View {
    /// The row the reader shows.
    @Binding var selection: FlaggedRow?
    /// Takes the row parked for this list, once: the one a layout swap
    /// closed, or a restored window's. The host knows which of the window's
    /// trees this list is in.
    let takeParked: () -> FlaggedNavigationState.Parked?

    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(SceneNavigator.self) private var navigator: SceneNavigator?
    /// The bar's trailing items lead in book pose (`\.listBarItemsLead`).
    @Environment(\.listBarItemsLead) private var listBarItemsLead
    /// Aims this list's compose requests at its own window.
    @Environment(\.commandWindowID) private var commandWindowID
    @State private var model: FlaggedListViewModel?
    @State private var hasAppeared = false
    /// A restored window's open item, until the rows that hold it load.
    @State private var awaited: ItemRef?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                FlaggedListBar(model: model, isOffline: appState.client?.reachability?.isReachable == false)
                list(model)
            } else {
                ProgressView("Loading flagged items…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(SmartView.flagged.title)
        .inlineNavigationTitle()
        .toolbar {
            // New Message keeps the slot the mail and feed lists give it,
            // so the primary action never moves between them.
            ToolbarItem(placement: .listBar(.primaryAction, leads: listBarItemsLead)) { composeButton }
                .keepsInBar()
            if HostPlatform.current.listBarOffersRefresh, let model {
                ToolbarItem(placement: .listBar(.automatic, leads: listBarItemsLead)) { refreshButton(model) }
            }
        }
        .answersCommand(.refresh) {
            guard let model else { return }
            Task { await model.refresh() }
        }
        .modifier(FlaggedItemCommands(model: model, row: selection))
        .task {
            guard let client = appState.client else { return }
            let window = navigator?.flaggedList(client: client, preferences: preferences, mailStore: appState.mailStore)
                ?? FlaggedListViewModel(client: client, preferences: preferences, mailStore: appState.mailStore)
            model = window
            window.start()
            applyParkedWhenReady()
            // The feed half follows the store for as long as the list is up.
            await window.observe()
        }
        .task {
            // A mail half that failed offline loads once the connection is
            // back, with no tap.
            guard let reachability = appState.client?.reachability else { return }
            for await reachable in reachability.changes() where reachable {
                model?.connectionReturned()
            }
        }
        .onAppear {
            hasAppeared = true
            applyParkedWhenReady()
        }
    }

    private var composeButton: some View {
        Button {
            appState.compose.open(seed: ReplyBuilder.newDraft(), from: commandWindowID)
        } label: {
            Label("New Message", systemImage: "square.and.pencil")
        }
        .keyboardShortcut("n", modifiers: .command)
        .accessibilityIdentifier("flagged.compose")
    }

    private func refreshButton(_ model: FlaggedListViewModel) -> some View {
        Button {
            Task { await model.refresh() }
        } label: {
            RefreshActivityIcon(isLoading: model.isRefreshing)
                .accessibilityLabel("Refresh flagged items")
        }
        .disabled(model.isRefreshing)
        .accessibilityIdentifier("flagged.refresh")
    }

    // MARK: The list

    private func list(_ model: FlaggedListViewModel) -> some View {
        ScrollViewReader { proxy in
            List(selection: refSelection(model)) {
                ForEach(model.page.rows) { row in
                    FlaggedListRow(row: row, model: model)
                        .tag(row.ref)
                        .id(row.ref)
                }
                FlaggedListFooter(model: model)
            }
            .listStyle(.plain)
            .refreshable { await model.refresh() }
            // A pick, or the first rows of the visit, start at the top.
            .onChange(of: model.listEpoch) {
                if let first = model.page.rows.first { proxy.scrollTo(first.ref, anchor: .top) }
            }
        }
        .onChange(of: selection?.ref) { previous, opened in
            // A new item opening, not the same one refreshed below.
            guard opened != previous, case .feed(let item)? = selection else { return }
            Task { await model.didOpen(item) }
        }
        // Rows are tagged by identity, so a row patched in place keeps its
        // highlight; the reader's copy follows the patch.
        .onChange(of: model.page.rows) { _, rows in
            resolveAwaited(model)
            guard let current = selection, let fresh = rows.first(where: { $0.ref == current.ref }),
                  fresh != current else { return }
            selection = fresh
        }
        // A message that left its folder (a dispose, a move) has no reader
        // to stay open in. One whose flag was cleared is still there, and
        // its reader stays.
        .onChange(of: model.removals) { _, removals in
            if case .mail(_, let ref)? = selection, removals.refs.contains(ref) { selection = nil }
        }
        .onChange(of: model.mailLoading) { resolveAwaited(model) }
    }

    /// The list selects a row by its identity; the host holds the row.
    private func refSelection(_ model: FlaggedListViewModel) -> Binding<ItemRef?> {
        Binding(
            get: { selection?.ref },
            set: { ref in selection = ref.flatMap { model.row(for: $0) } }
        )
    }

    // MARK: A parked row

    /// Opens the row parked for this list, once the list is on screen: any
    /// earlier and a collapsed stack is handed a list and a reader in one
    /// update, which leaves a reader that never loads (#1664). A row a
    /// layout swap closed reopens whole. A restored window's item is known
    /// by identity only, so it waits for the rows that hold it.
    private func applyParkedWhenReady() {
        guard hasAppeared, let model, selection == nil, let parked = takeParked() else { return }
        switch parked {
        case .row(let row):
            selection = model.row(for: row.ref) ?? row
        case .ref(let ref):
            awaited = ref
            resolveAwaited(model)
        }
    }

    /// Opens the awaited item once its row has loaded, and gives up once
    /// the mail half has answered without it: it is no longer flagged, or
    /// it is past the first page.
    private func resolveAwaited(_ model: FlaggedListViewModel) {
        guard let ref = awaited else { return }
        switch model.awaited(ref) {
        case .found(let row):
            awaited = nil
            if selection == nil { selection = row }
        case .gone:
            awaited = nil
        case .waiting:
            break
        }
    }
}

/// One row of the Flagged list: a message's or a feed item's, with its
/// medium's glyph, its swipes and its menu.
private struct FlaggedListRow: View {
    let row: FlaggedRow
    let model: FlaggedListViewModel
    @Environment(Preferences.self) private var preferences

    var body: some View {
        let actions = FlaggedRowActions(model: model)
        switch row {
        case .mail(let envelope, let ref):
            decorated(
                source: .mail,
                leading: actions.mailSwipe(preferences.swipeLeading, envelope: envelope, ref: ref),
                trailing: actions.mailSwipe(preferences.swipeTrailing, envelope: envelope, ref: ref)
            ) {
                FlaggedMailRow(envelope: envelope, folderPath: ref.folder, palette: model.flagPalette)
            }
            .contextMenu { mailMenu(envelope, ref, actions) }
            // `.contain` keeps the row's children (and its revealed swipe
            // buttons) reachable; a bare identifier would be stamped on
            // every one of them.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flagged.message.\(ref.folder)#\(ref.uid)")
        case .feed(let item):
            decorated(
                source: .feed,
                leading: actions.feedSwipe(model.swipeLeading, item: item),
                trailing: actions.feedSwipe(model.swipeTrailing, item: item)
            ) {
                FeedItemRow(
                    item: item, feedName: model.feedName(for: item),
                    isPending: model.pendingIDs.contains(item.id), palette: model.flagPalette
                )
            }
            .contextMenu { feedMenu(item) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flagged.item.\(item.id)")
        }
    }

    /// The row with its medium's glyph and its two swipe edges. An edge
    /// with no spec carries no swipe at all.
    private func decorated<Content: View>(
        source: FlaggedSource, leading: SwipeActionSpec?, trailing: SwipeActionSpec?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            content()
            FlaggedMediumGlyph(source: source)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let leading { leading.revealedButton }
        }
        .swipeActions(edge: .trailing) {
            if let trailing { trailing.revealedButton }
        }
    }

    /// A message's menu: read, the default flag, every other flag the
    /// palette offers, and the dispose its own folder gives it.
    @ViewBuilder
    private func mailMenu(_ envelope: Envelope, _ ref: MessageRef, _ actions: FlaggedRowActions) -> some View {
        let read = actions.readSpec(envelope, ref)
        Button(envelope.flags.contains(.seen) ? "Mark as Unread" : "Mark as Read", action: read.perform)
        let flag = actions.flagSpec(envelope, ref)
        Button(flag.title, action: flag.perform)
        let rows = FlagMenuPolicy.rows(
            palette: model.flagPalette,
            taggedSlots: Set(FlagPalette.slots(in: envelope.flags, palette: model.flagPalette))
        )
        if !rows.isEmpty {
            Menu("Flags") {
                FlagMenuToggles(rows: rows) { row in
                    Task { await model.toggle(Flag(wireValue: row.slot), on: ref) }
                }
            }
        }
        if let dispose = actions.disposeSpec(ref) {
            Divider()
            Button(dispose.title, role: dispose.role, action: dispose.perform)
        }
    }

    /// A feed item's menu, as the feed list's own row menu reads.
    @ViewBuilder
    private func feedMenu(_ item: RssItem) -> some View {
        Button(item.isRead ? "Mark as unread" : "Mark as read") {
            Task { await model.setRead(item, !item.isRead) }
        }
        let toggle = model.defaultFlag
        Button(toggle.title(isSet: item.carries(slot: toggle.slot))) {
            Task { await model.toggleDefaultFlag(on: item) }
        }
        let rows = FlagMenuPolicy.rows(
            palette: model.flagPalette,
            taggedSlots: Set(FlagPalette.slots(in: item.paletteFlags, palette: model.flagPalette))
        )
        if !rows.isEmpty {
            Menu("Flags") {
                FlagMenuToggles(rows: rows) { row in
                    Task { await model.toggleFlag(slot: row.slot, on: item) }
                }
            }
        }
        if let url = URL(string: item.url) {
            Link("Open in browser", destination: url)
        }
    }
}
