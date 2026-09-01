import SwiftUI
import CabalmailKit

// Sort-menu toolbar item. Pulled into a sibling extension so the primary
// MessageListView body stays under SwiftLint's `type_body_length` cap.
//
// Layout: a `Menu` offering the four sort fields, a separator, and the two
// directions, with the row in effect carrying the native menu checkmark in
// each group. Mirrors the React webmail's "Sort by […] ▼ ↓" strip in
// `react/admin/src/Email/Messages/index.jsx`; the direction is two marked
// rows rather than that strip's single flip button because a menu row's
// own state is what an assistive client reads (#1367).
extension MessageListView {
    @ViewBuilder
    var sortMenu: some View {
        let rows = model.map { SortMenuPolicy.rows(criterion: $0.sortCriterion) } ?? []
        Menu {
            if let model {
                sortMenuItems(rows: rows, model: model)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .accessibilityLabel("Sort")
        }
        .disabled(model == nil)
        .accessibilityIdentifier("list.sort")
        // macOS keeps the AppKit menu it built the first time this `Menu`
        // was opened — checkmarks and row titles included — so the identity
        // carries what the rows draw (#1337, same mechanism as #1329).
        .id(SortMenuPolicy.identity(rows))
    }

    /// The menu's rows: the sort fields, then the direction pair. Menu
    /// toggles rather than buttons drawing their own checkmark glyph, so
    /// the row in effect carries the native mark an assistive client can
    /// read (#1367).
    ///
    /// Each row reads its own drawn state off the row rather than the
    /// criterion, so what is drawn and what the menu's identity is built
    /// from can never disagree.
    @ViewBuilder
    private func sortMenuItems(
        rows: [ReaderMenuRow<SortMenuOption>],
        model: MessageListViewModel
    ) -> some View {
        ForEach(rows) { row in
            if row.startsGroup { Divider() }
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in
                    Task {
                        await model.setSort(SortMenuPolicy.criterion(
                            picking: row.option,
                            from: model.sortCriterion
                        ))
                    }
                }
            )) {
                Text(row.label)
            }
        }
    }
}
