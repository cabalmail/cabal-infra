import SwiftUI

/// The global search control — magnifying-glass icon, query field and clear
/// button on a rounded translucent background — shared by both of its hosts
/// (`GlobalSearchFieldPlacement`): the message-list column's toolbar on macOS
/// and visionOS, a header row inside that column on iPadOS. Compact iPhone
/// searches from its own tab and never mounts this.
///
/// Styling matches `SidebarListHeaderRow`'s filter field, which is the same
/// shape one column over.
struct GlobalSearchField: View {
    @Binding var query: String
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all mail", text: $query)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onSubmit)
            if !query.isEmpty {
                Button {
                    // Zeroing the query lets the mounted search list's
                    // `onChange(of: searchQuery)` drop search mode; dropping
                    // focus then swaps the content column back to the folder.
                    query = ""
                    isFocused = false
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
    }
}
