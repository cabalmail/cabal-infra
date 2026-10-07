import SwiftUI

/// The rows of a list column's title-switch menu: the folder menu above the
/// message list and the scope menu above the feed item list both draw their
/// choices with this.
///
/// The rows are `Toggle`s rather than buttons drawing a checkmark glyph, so
/// the choice in effect carries the native mark an assistive client reads
/// (#1367). On macOS that brings the materialize-once behaviour the sort menu
/// documents (#1329, #1337), so each caller keys its `Menu` by an identity
/// that carries what the rows draw.
struct TitleSwitchMenuRows<Option: Hashable>: View {
    let rows: [ReaderMenuRow<Option>]
    /// The SF Symbol drawn beside each row's label.
    let symbol: (Option) -> String
    let pick: (Option) -> Void

    var body: some View {
        ForEach(rows) { row in
            Toggle(isOn: Self.isOn(row, pick: pick)) {
                Label(row.label, systemImage: symbol(row.option))
            }
        }
    }

    /// A row's toggle: on for the choice in effect, and a pick of any other
    /// row switches to it. Re-picking the choice the list is already on is a
    /// no-op: the parent would only re-key the same view.
    static func isOn(_ row: ReaderMenuRow<Option>, pick: @escaping (Option) -> Void) -> Binding<Bool> {
        Binding(
            get: { row.isOn },
            set: { _ in
                guard !row.isOn else { return }
                pick(row.option)
            }
        )
    }
}

#if os(macOS)
extension View {
    /// Puts a list column's title-switch menu where its toolbar title was.
    ///
    /// macOS draws a column's navigation title as bold text at the leading
    /// edge of the column's toolbar section but never materializes a
    /// `toolbarTitleMenu` for it (probed on macOS 26, re-probed on 27 for
    /// #1601), so the Mac removes the title text and puts the menu in the
    /// same slot as a `.navigation` item. The window keeps its title for the
    /// Window menu and Mission Control.
    ///
    /// On macOS 26's liquid glass the toolbar wraps the item in a glass
    /// capsule, so the name reads as a bordered control with the name flush
    /// against the capsule's edge. The title it stands in for is bare text,
    /// so the item is detached from the shared background where the API
    /// exists (same treatment as the brand mark in `SidebarBranding`);
    /// earlier systems draw a borderless menu plain anyway.
    func titleSwitchToolbarHost<Menu: View>(@ViewBuilder _ menu: () -> Menu) -> some View {
        let menu = menu()
        return self
            .toolbar(removing: .title)
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItem(placement: .navigation) { menu }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .navigation) { menu }
                }
            }
    }
}
#endif
