import SwiftUI

extension View {
    /// Applies the sidebar filter `.searchable` only when `enabled`.
    ///
    /// `.searchable(placement: .sidebar)` is hoisted by the system to the very
    /// top of the sidebar column. On the wide (macOS / iPad-regular) layout the
    /// global "Search all mail" field owns that top slot, and the per-context
    /// folder/address filter is rendered as a plain field *below* the section
    /// tabs instead — so the list view passes `enabled: false` to suppress its
    /// own searchable and filters by the parent-owned binding. Compact passes
    /// `enabled: true` to keep the self-contained sidebar searchable.
    @ViewBuilder
    func sidebarFilterSearchable(text: Binding<String>, enabled: Bool, prompt: String) -> some View {
        if enabled {
            searchable(text: text, placement: .sidebar, prompt: Text(prompt))
        } else {
            self
        }
    }
}
