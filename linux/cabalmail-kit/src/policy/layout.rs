//! Which pane an `AdwNavigationSplitView` shows once it has collapsed, and at
//! what width it collapses.
//!
//! The Apple analog is `CompactColumnPolicy`, which decides the same thing for
//! a `NavigationSplitView` in its compact size class. The rule is the part
//! worth porting; the widget it drives is not.

/// A pane of the three-column split: folders, the message list, the reader.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Pane {
    Sidebar,
    Content,
    Detail,
}

/// The window width below which the split view shows one pane at a time.
///
/// libadwaita's own adaptive breakpoint for a two-pane split, and the width
/// GNOME's HIG calls the boundary between a narrow and a normal window. The
/// `AdwBreakpoint` that acts on it arrives with the shell in Phase 4; until
/// then this is the one place the number is written.
pub const COLLAPSE_WIDTH_SP: i32 = 720;

/// Whether a window of `width_sp` scaled pixels shows one pane or three.
#[must_use]
pub fn is_collapsed(width_sp: i32) -> bool {
    width_sp < COLLAPSE_WIDTH_SP
}

/// The pane a collapsed split view should show after the read message
/// changed.
///
/// With a selection, the reader. Without one the message being read is gone —
/// pruned by a send, an archive, or a move made from the reader itself — and a
/// collapsed navigation has no list beside the reader to fall back on, so
/// leaving the pane on `Detail` strands the user on an empty-selection
/// placeholder whose copy is addressed to a layout that is not on screen. Pop
/// back to the list instead. A selection cleared while the reader is *not* up
/// — a folder switch clearing both at once — leaves the pane where it is.
#[must_use]
pub fn visible_pane(has_selected_message: bool, current: Pane) -> Pane {
    if has_selected_message {
        return Pane::Detail;
    }
    if current == Pane::Detail {
        Pane::Content
    } else {
        current
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_selection_always_shows_the_reader() {
        for current in [Pane::Sidebar, Pane::Content, Pane::Detail] {
            assert_eq!(visible_pane(true, current), Pane::Detail);
        }
    }

    /// The defect the rule exists for: disposing of the message being read
    /// leaves the reader on screen with nothing in it and no way back.
    #[test]
    fn losing_the_read_message_pops_back_to_the_list() {
        assert_eq!(visible_pane(false, Pane::Detail), Pane::Content);
    }

    /// A folder switch clears the selection while the reader is not up. Moving
    /// the pane then would yank the user out of the sidebar they just tapped.
    #[test]
    fn a_cleared_selection_elsewhere_leaves_the_pane_alone() {
        assert_eq!(visible_pane(false, Pane::Sidebar), Pane::Sidebar);
        assert_eq!(visible_pane(false, Pane::Content), Pane::Content);
    }

    #[test]
    fn the_breakpoint_is_exclusive_at_its_own_width() {
        assert!(is_collapsed(COLLAPSE_WIDTH_SP - 1));
        assert!(!is_collapsed(COLLAPSE_WIDTH_SP));
        assert!(!is_collapsed(COLLAPSE_WIDTH_SP + 1));
    }
}
