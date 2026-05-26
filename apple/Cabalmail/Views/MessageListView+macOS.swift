#if os(macOS)
import SwiftUI
import CabalmailKit

// Inline search field for macOS. `.searchable` would otherwise place the
// search box in the window toolbar at the trailing edge, which on a
// 3-column `NavigationSplitView` sits visually over the message detail
// column rather than the message list. Rendering a plain TextField in
// the content column's top safe-area inset keeps the search affordance
// where the iPad client puts it: directly above the message list.
//
// Same-file `#if` toggles in `MessageListView.swift` flip between this
// inline path (macOS) and the platform `.searchable` modifier
// (everything else).
extension MessageListView {
    @ViewBuilder
    func inlineSearchField(
        model: MessageListViewModel,
        focused: FocusState<Bool>.Binding
    ) -> some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search mailbox", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit {
                    Task { await model.runSearch() }
                }
            if !model.searchQuery.isEmpty {
                Button {
                    // Just zero out the text — `MessageListView`'s
                    // `.onChange(of: model.searchQuery)` handler picks up
                    // the empty value and drops back to the folder view
                    // when a search is currently active.
                    model.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.secondary.opacity(0.12))
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
#endif
