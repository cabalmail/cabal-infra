import SwiftUI
import CabalmailKit

/// Global, cross-folder search surface for compact iPhone — the content of the
/// `Tab(role: .search)` tab.
///
/// `.searchable` here is what drives the iOS 26 tab-bar morph (the tab bar
/// collapses to a dismiss button and the search button expands into a focused
/// field, like the Apple Store app); on iOS 18–25 it's an ordinary search tab.
/// The field binds a `.search`-scope `MessageListViewModel`, which renders
/// results with the same row machinery as the folder list (swipe, multi-select,
/// context menus, move) — `MessageListView` in `.search` scope. Tapping a result
/// pushes the reader against that result's true source mailbox, so mark-read /
/// archive / move land in the right folder.
///
/// iPad / macOS reach the same `.search`-scope list through `MailRootView`'s
/// sidebar search field instead (no bottom tab bar there), so this view is the
/// compact-width surface only.
struct SearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(Preferences.self) private var preferences

    /// Owned here (not by `MessageListView`) so `.searchable` can bind its
    /// `searchQuery`; injected into the list, which skips the folder lifecycle
    /// in `.search` scope.
    @State private var model: MessageListViewModel?
    @State private var selectedEnvelope: Envelope?

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
                    MessageDetailView(
                        folder: Folder(path: model.sourceFolder(for: envelope)),
                        envelope: envelope
                    )
                }
            }
        }
        .task {
            if model == nil, let client = appState.client {
                model = MessageListViewModel(
                    scope: .search,
                    client: client,
                    preferences: preferences,
                    appState: appState
                )
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
            addressFilter: nil,
            onClearAddressFilter: {},
            onSearchResultSelected: { _ in },
            onSelectionCountChanged: { _ in }
        )
        .searchable(text: $model.searchQuery, prompt: "Search all mail")
        .onSubmit(of: .search) {
            Task { await model.runSearch() }
        }
    }
}
