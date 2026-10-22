import Foundation
import CabalmailKit

/// Which of a wide list's selected rows the reading pane reads (#2032).
///
/// On a wide layout a plain click selects one row and the pane shows it, so
/// the pane is derived from `selectedRefs`. Select mode's checkboxes write
/// that same set, which made one checked box open its message and the
/// mark-read-on-open rule write the read flag to the server — a bulk
/// selection is a list of rows to act on, not a request to read one. So
/// while Select mode is on the pane shows no message however many rows are
/// checked, and the count placeholder stands in for them
/// (`MailReaderChoice`).
enum ReadingPaneSelectionPolicy {
    /// The row whose message the pane should show, nil for none.
    static func shown(selectedRefs refs: Set<MessageRef>, bulkMode: Bool) -> MessageRef? {
        guard !bulkMode, refs.count == 1 else { return nil }
        return refs.first
    }

    /// Whether a tap on `ref` must write the pane itself, because selecting
    /// that row changes nothing for `.onChange` to hear (#2033, #2034).
    ///
    /// The pane is derived from `selectedRefs`, so a tap that assigns a set
    /// equal to the one already there fires no change and leaves the pane as
    /// it was. The pane can be empty while the set still names the row: a
    /// pushed reader popping clears it (visionOS's search tab, #2034), and so
    /// does a compact-to-regular layout swap (iPad mid-search, #2033). The
    /// surviving highlight then marked a row whose tap did nothing at all,
    /// until another row was tapped and it in turn went dead. So an equal set
    /// re-opens, and only then: a set the tap really changes is the
    /// derivation's own job, and a row the pane would not show anyway (Select
    /// mode, per `shown`) must not be opened by a tap either.
    static func reopens(
        selectedRefs refs: Set<MessageRef>,
        tapped ref: MessageRef,
        paneShowing shown: MessageRef?,
        bulkMode: Bool
    ) -> Bool {
        guard self.shown(selectedRefs: [ref], bulkMode: bulkMode) == ref else { return false }
        guard refs == [ref] else { return false }
        return shown != ref
    }
}
