import SwiftUI
import CabalmailKit

/// Global, cross-folder search surface for compact iPhone and visionOS — the
/// content of their search tab (`Tab(role: .search)` on iPhone).
///
/// `.searchable` here is the field the iPhone's search tab morphs into: on
/// iOS 26 and later, tapping Search turns the button into this field at the
/// bottom and collapses the rest of the bar to one button for the tab the
/// user came from (`TabShell`). Until a search runs, the tab shows that tab's
/// screen, dimmed (`backdrop`); the results take over once one is submitted.
/// The field binds a `.search`-scope `MessageListViewModel`, which renders
/// results with the folder list's row machinery (`MessageListView` in
/// `.search` scope). Tapping a result pushes the reader against that result's
/// true source mailbox, so mark-read / archive / move land in the right folder.
///
/// iPad / macOS reach the same list through the global search field
/// the wide shells mount on the message-list column (`GlobalSearchFieldPlacement`).
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

    /// The tab that was in front when Search was tapped, shown until a search
    /// runs (`SearchBackdrop`). Nil on visionOS, and on the phone when Search
    /// opened some other way (a fold or a narrowing that carried a search
    /// across).
    let backdrop: SearchBackdrop?

    /// Drives the `.searchable` field so the tab arrives ready to type (#1425).
    @FocusState private var searchFieldFocused: Bool

    init(backdrop: SearchBackdrop? = nil) {
        self.backdrop = backdrop
    }

    var body: some View {
        NavigationStack {
            Group {
                if let backdrop, backdropStandsIn {
                    backdropView(backdrop)
                } else if let model {
                    searchList(model: model)
                } else {
                    ProgressView()
                }
            }
            // On the group, not the list, so the field is there whichever of
            // the three is showing: the backdrop is what the field opens over.
            .searchable(text: query, prompt: "Search all mail")
            .searchFocused($searchFieldFocused)
            .onSubmit(of: .search) {
                guard let model else { return }
                Task { await model.runSearch() }
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
            // cleared here — through `setSearchAnchor`, which also drops a
            // "This folder only" the split's search was narrowed by, and
            // re-runs it across folders. Cleared in place, the filter stayed
            // on with no folder behind it and no toggle to turn it off. The
            // model is shown first, so a re-run doesn't hold the tab on its
            // spinner.
            if model == nil, let client = appState.client {
                let window = navigator.searchModel(
                    client: client, preferences: preferences, mailStore: appState.mailStore
                )
                model = window
                await window.setSearchAnchor(nil)
            }
        }
    }

    /// The field's text: the model's query, once the model is in.
    private var query: Binding<String> {
        Binding(get: { model?.searchQuery ?? "" }, set: { model?.searchQuery = $0 })
    }

    private var backdropStandsIn: Bool {
        SearchBackdrop.standsIn(
            submittedQuery: model?.search.submittedQuery ?? "",
            isSearchActive: model?.isSearchActive ?? false
        )
    }

    /// The tab the user came from, as it last looked, dimmed. It has its own
    /// bar in the picture, so this screen draws none; a tap goes back to it.
    private func backdropView(_ backdrop: SearchBackdrop) -> some View {
        backdrop.image
            .resizable()
            .overlay { Color.black.opacity(SearchBackdrop.dimming) }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture { backdrop.returnToTab() }
            .accessibilityElement()
            .accessibilityLabel("Back to \(backdrop.tabTitle)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { backdrop.returnToTab() }
            .accessibilityIdentifier("search.backdrop")
            .hiddenNavigationBar()
    }

    private func searchList(model: MessageListViewModel) -> some View {
        MessageListView(
            scope: .search,
            injectedSearchModel: model,
            selection: $selectedEnvelope,
            onSelectionCountChanged: { selectionCount = $0 }
        )
        .onAppear {
            // The tab has one thing to type into, so opening it is the whole
            // of the intent — unless a previous search is still on screen,
            // which the keyboard would cover (#1425).
            searchFieldFocused = SearchFieldFocusPolicy.focusesOnAppear(
                query: model.searchQuery
            )
        }
    }
}
