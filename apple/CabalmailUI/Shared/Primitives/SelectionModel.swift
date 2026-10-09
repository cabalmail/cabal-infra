import Observation

/// A list's selection: the rows picked, the Select mode that picks them on
/// touch layouts, and the pivot and moving end a range selection works from.
///
/// It is an object of its own, rather than state on the list's view model,
/// so that it can outlive the model. A layout swap (an iPhone Duo fold, an
/// iPad window crossing the size-class line) builds a new view tree with a
/// new message list and a new view model; the window's navigator holds the
/// folder list's selection and hands it to that list
/// (`SceneNavigator.mailSelection(for:)`), so a multi-selection survives
/// the swap. Generic over the row identity, as `RangeSelectionPolicy` is.
@MainActor
@Observable
final class SelectionModel<ID: Hashable> {
    /// Select mode: rows draw checkboxes and a tap toggles one rather than
    /// opening it.
    var bulkMode = false

    /// The rows picked.
    var selected: Set<ID> = []

    /// The fixed pivot a shift-click or shift-arrow extends from: the last
    /// row plainly selected or command-clicked. Set only through
    /// `setAnchor(_:)`, so it cannot drift out of step with `rangeBase`.
    private(set) var anchor: ID?

    /// What was selected when `anchor` was pinned, which a range operation
    /// unions its span onto (`RangeSelectionPolicy`, #1768). Never written
    /// on its own: a base left over from an earlier anchor would bring back
    /// rows the user has since dropped.
    private(set) var rangeBase: Set<ID> = []

    /// The moving end of a keyboard range selection: the row a plain arrow
    /// last landed on, or a shift-arrow last extended to.
    var cursor: ID?

    init() {}

    /// Pins the pivot for range selection, recording the selection it
    /// starts from. The anchor and its base always move together.
    func setAnchor(_ id: ID?) {
        anchor = id
        rangeBase = selected
    }

    /// Readies the selection for the list a layout swap builds, and says
    /// whether it goes across. Select mode and a multi-selection do. A lone
    /// selection outside Select mode stays behind: it is the open message,
    /// which the window's route carries and the new list selects once it
    /// has loaded. The compact layout draws a multi-selection only as Select
    /// mode's checkboxes, so arriving there turns Select mode on; the wide
    /// layouts draw either.
    func handOff(toWide isWide: Bool) -> Bool {
        guard bulkMode || selected.count > 1 else { return false }
        if !isWide { bulkMode = true }
        return true
    }
}
