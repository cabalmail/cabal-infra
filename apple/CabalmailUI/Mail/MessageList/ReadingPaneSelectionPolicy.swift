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
}
