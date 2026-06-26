import SwiftUI

/// Wide-sidebar (iPad-regular / macOS) header row for the folder and address
/// lists: the per-context filter field flanked by the list's New (`+`) button on
/// the leading edge and its Reload button on the trailing edge. Pulls those two
/// actions out of the sidebar column's navigation toolbar and down beneath the
/// Folders/Addresses tabs, next to the filter they act on.
///
/// Rendered by `FolderListView` / `AddressListView` only when their
/// `externalFilter` binding is present (the wide layout); compact keeps the
/// buttons in the toolbar and the filter in a `.searchable`. The filter field's
/// styling matches the search field above the tabs in `MailRootView`.
struct SidebarListHeaderRow: View {
    let newAction: () -> Void
    let newDisabled: Bool
    let newAccessibilityLabel: String
    @Binding var filterText: String
    let filterPrompt: String
    let isRefreshing: Bool
    let refreshDisabled: Bool
    let refreshAccessibilityLabel: String
    let refreshAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: newAction) {
                Image(systemName: "plus")
                    .accessibilityLabel(newAccessibilityLabel)
            }
            .buttonStyle(.borderless)
            .disabled(newDisabled)

            filterField

            Button(action: refreshAction) {
                RefreshActivityIcon(isLoading: isRefreshing)
                    .accessibilityLabel(refreshAccessibilityLabel)
            }
            .buttonStyle(.borderless)
            .disabled(refreshDisabled)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(.secondary)
            TextField(filterPrompt, text: $filterText)
                .textFieldStyle(.plain)
            if !filterText.isEmpty {
                Button {
                    filterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
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
