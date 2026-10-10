import SwiftUI
import CabalmailKit

/// Global, cross-folder search surface for compact iPhone and visionOS — the
/// content of their search tab (`Tab(role: .search)` on iPhone).
///
/// `.searchable` here drives the iOS 26 tab-bar morph (the bar collapses to a
/// dismiss button and the search button expands into a focused field).
/// The field binds a `.search`-scope `MessageListViewModel`, which renders
/// results with the folder list's row machinery (`MessageListView` in
/// `.search` scope). Tapping a result pushes the reader against that result's
/// true source mailbox, so mark-read / archive / move land in the right folder.
///
/// iPad / macOS reach the same list through the global search field
/// `MailRootView` mounts on the message-list column (`GlobalSearchFieldPlacement`).
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences
    @Environment(SceneNavigator.self) private var navigator

    /// The window's search model, shared with the regular split's search
    /// (`SceneNavigator.searchModel`, #1654), held here so `.searchable` can
    /// bind its `searchQuery`; injected into the list.
    @State private var model: MessageListViewModel?
    @State private var selectedEnvelope: Envelope?
    /// The list's selection count, for the Message menu (`wideList` reports it).
    @State private var selectionCount = 0

    /// Drives the `.searchable` field so the tab arrives ready to type (#1425).
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    searchList(model: model)
                } else {
                    ProgressView()
                }
            }
            .navigationDestination(item: $selectedEnvelope) { envelope in
                if let model {
                    // Every result carries its source folder, so the reader's
                    // operations target the message's true mailbox.
                    let folder = MessageFolderPolicy.folder(for: envelope, in: nil)
                        ?? Folder(path: model.rowRef(for: envelope).folder)
                    // Keyed on the message, as the split's reader is: an
                    // archive from the reader moves the selection on to the
                    // next result while this destination stays pushed, and
                    // the reader must be rebuilt for it rather than keep the
                    // archived message's model behind the new header.
                    MessageDetailView(folder: folder, envelope: envelope)
                        .id("\(folder.path)#\(envelope.uid)")
                }
            }
            // On iPhone the Cabalmail mark heads the tab like every other
            // compact tab (see `SidebarBranding.swift`); the title string is
            // for VoiceOver and the reader's back button. visionOS keeps its
            // untitled search tab.
            #if os(iOS)
            .navigationTitle("Search")
            .compactBrandMarkTitle(accessibilityTitle: "Search")
            #endif
        }
        // What the Message menu acts on while this tab is in front: the
        // results' selection and the reader pushed over them.
        .reportsMessageMenuAvailability(selectedCount: selectionCount, hasOpenMessage: selectedEnvelope != nil)
        .task {
            // The window's, shared with its regular split's search so a
            // layout swap keeps the query and results (#1654). This tab
            // searches everywhere, so the anchor the split may have set is
            // cleared here.
            if model == nil, let client = appState.client {
                let window = navigator.searchModel(
                    client: client, preferences: preferences, mailStore: appState.mailStore
                )
                window.searchAnchor = nil
                model = window
            }
        }
    }

    @ViewBuilder
    private func searchList(model: MessageListViewModel) -> some View {
        @Bindable var model = model
        MessageListView(
            scope: .search,
            injectedSearchModel: model,
            selection: $selectedEnvelope,
            onSelectionCountChanged: { selectionCount = $0 }
        )
        .searchable(text: $model.searchQuery, prompt: "Search all mail")
        .searchFocused($searchFieldFocused)
        .onAppear {
            // The tab has one thing to type into, so opening it is the whole
            // of the intent — unless a previous search is still on screen,
            // which the keyboard would cover (#1425).
            searchFieldFocused = SearchFieldFocusPolicy.focusesOnAppear(
                query: model.searchQuery
            )
        }
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
    }
}
