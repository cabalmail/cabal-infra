import Foundation

/// The user's in-progress input for `NewFolderSheet`, owned by the view that
/// presents the sheet rather than by the sheet itself.
///
/// The sheet used to hold `name` and `parent` in its own `@State`. On compact
/// iPhone that state is lost whenever SwiftUI re-creates the sheet's body —
/// which is exactly what dismissing the parent `Picker`'s menu does, wiping
/// the typed name and dropping the selection on the floor (#889). The
/// presenting view outlives that churn, so keeping the input here is what
/// makes it stick; the sheet reads and writes it through `@Bindable`.
@Observable
final class NewFolderForm {
    /// Folder name as typed. Not trimmed — `canCreate` and `submissionName`
    /// decide what counts as usable.
    var name: String = ""

    /// Selected parent path, or `""` for the picker's "None (top level)" row.
    var parent: String = ""

    /// The parent to create under: nil when the user left it at top level.
    var chosenParent: String? {
        parent.isEmpty ? nil : parent
    }

    /// Whitespace-only input is not a folder name.
    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Cleared before each presentation so a new sheet starts empty rather
    /// than showing whatever the last one was carrying.
    func reset() {
        name = ""
        parent = ""
    }
}
