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
    /// Folder name as typed. Not trimmed — `canCreate` decides whether the
    /// Create button is usable, and `FolderListViewModel.createFolder` trims
    /// before it submits.
    var name: String = ""

    /// Selected parent path, or `""` for the picker's "None (top level)" row.
    var parent: String = ""

    /// The parent to create under: nil when the user left it at top level.
    var chosenParent: String? {
        parent.isEmpty ? nil : parent
    }

    /// Why the last Create failed, for the sheet to show. It lives here for
    /// the same reason the input does: the sheet's own state would lose it
    /// when its body is re-created. The sidebar's error line is behind the
    /// sheet, so a failure written there went unseen (#1915).
    private(set) var errorMessage: String?

    /// Whitespace-only input is not a folder name.
    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Runs `create` with the typed name and chosen parent. True when it
    /// succeeded and the sheet can close; a failure's sentence stays in
    /// `errorMessage` and the sheet stays open.
    @MainActor
    func submit(_ create: (String, String?) async throws -> Void) async -> Bool {
        errorMessage = nil
        do {
            try await create(name, chosenParent)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Cleared before each presentation so a new sheet starts empty rather
    /// than showing whatever the last one was carrying.
    func reset() {
        name = ""
        parent = ""
        errorMessage = nil
    }
}
