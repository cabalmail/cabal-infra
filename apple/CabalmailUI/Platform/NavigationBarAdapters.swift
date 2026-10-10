import SwiftUI

// What a navigation bar takes on the platforms that draw one. A Mac window
// has a toolbar and no navigation bar, so each of these is nothing there.
// They are here so a feature view calls one line instead of writing the
// platform conditional itself (`docs/apple.md`, "Platform conditionals").

extension View {
    /// The compact, centred title a pushed screen or a sheet shows:
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS and visionOS.
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The bar's Edit toggle for a list that reorders or deletes in edit
    /// mode, at the bar's default placement. macOS has no edit mode: its
    /// lists reorder and delete directly.
    func editButtonToolbar() -> some View {
        #if os(macOS)
        self
        #else
        toolbar { EditButton() }
        #endif
    }
}

/// The same Edit toggle as an item among a toolbar's others, on the bar's
/// trailing side. On macOS it is no item at all.
struct EditButtonToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        #if os(macOS)
        // No item. An empty arm would be `EmptyView`, which is toolbar
        // content only from the 27.0 systems; `Optional` has been since 13.
        ToolbarItem<Void, EmptyView>?.none
        #else
        ToolbarItem(placement: .topBarTrailing) { EditButton() }
        #endif
    }
}
