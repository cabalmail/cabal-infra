import Foundation

/// Whether a folder-list *section* is drawing its rows, and how its header
/// draws the control that says so.
///
/// A pure rule rather than a `Section(_:isExpanded:)` because the list style
/// decides both halves and no two platforms decide them the same way: on
/// macOS and visionOS the binding is honoured but the header draws no
/// disclosure control at all, so a section collapsed by default has nothing
/// marked to open it (#1184 — `All folders` defaults collapsed; on visionOS
/// that stranded `Sent`, `Trash` and `Drafts`, and on macOS 26 and 27 alike
/// the header *text* was still a live click target that toggled the section
/// both ways, so there it was a discoverability bug rather than a dead end);
/// on iPadOS the header is equally inert but the rows are drawn regardless,
/// so the stored expansion state does nothing.
/// Owning the gating and the control here makes the three agree, and makes
/// them testable: `FolderListView`'s body isn't reachable from a unit test,
/// this is.
///
/// Deliberately not a `DisclosureGroup` holding the rows: that is itself a
/// row of the enclosing `List`, which is what drew the "All folders" header
/// as a ghost of a folder row (#1070). A `Section` header stays list chrome.
enum FolderSectionDisclosure {
    /// The rows the section actually draws. Collapsed means none — the rule
    /// two of the three platforms got wrong when it was theirs to apply.
    static func visibleRows(_ rows: [FolderSectionRow], isExpanded: Bool) -> [FolderSectionRow] {
        isExpanded ? rows : []
    }

    /// Rotation for the header chevron, in degrees. One glyph rotated,
    /// matching the per-folder chevron in `FolderListView.row(for:...)`
    /// rather than swapping between two symbols.
    static func chevronRotation(isExpanded: Bool) -> Double {
        isExpanded ? 90 : 0
    }

    /// VoiceOver label for the header control. Names the action, the way the
    /// folder rows' own disclosure buttons do ("Expand alpha" / "Collapse
    /// alpha"), so the two chevrons in the sidebar read alike.
    static func accessibilityLabel(title: String, isExpanded: Bool) -> String {
        isExpanded ? "Collapse \(title)" : "Expand \(title)"
    }
}
