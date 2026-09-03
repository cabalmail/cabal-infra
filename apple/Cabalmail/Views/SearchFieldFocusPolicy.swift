import Foundation

/// Whether the compact Search tab should claim keyboard focus for its field
/// the moment the surface appears.
///
/// Issue #1425: opening the Search tab left the field unfocused, so reaching a
/// search term cost two taps — one to open the tab, one to focus the field.
/// The tab has exactly one thing to type into, so the second tap carries no
/// information.
///
/// It is not unconditional, because the tab is also where results live. A tab
/// re-entered with a term still in the field is showing an answer, and raising
/// the keyboard over it would cover the rows the user came back to read. So
/// the rule is the report's own condition: focus when there is nothing to
/// come back to.
enum SearchFieldFocusPolicy {
    /// - Parameter query: the search field's current text.
    /// - Returns: `true` when the field should take focus on appearance.
    static func focusesOnAppear(query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
