import SwiftUI

/// A flag menu's rows as checkmark toggles: the reader's flag menu and the
/// row menu's Flags submenu, for a message and for a feed item. The rows
/// are `FlagMenuPolicy.rows`; what a pick does to the item is the caller's.
///
/// Toggles rather than buttons drawing a checkmark glyph, so a set flag
/// carries the native mark an assistive client reads. `isOn` reads the row
/// rather than the item, so the drawn state and the menu's identity
/// (`FlagMenuPolicy.identity`) can never disagree.
struct FlagMenuToggles: View {
    let rows: [FlagMenuRow]
    /// A row was picked: flip that flag on the item.
    let toggle: (FlagMenuRow) -> Void

    var body: some View {
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { row.isOn },
                set: { _ in toggle(row) }
            )) {
                Text(row.label)
            }
        }
    }
}
