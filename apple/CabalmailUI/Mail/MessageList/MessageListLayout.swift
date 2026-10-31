/// Which of its two paths the message list takes on a window's layout.
///
/// The wide path is the Mac's: a multi-selection the hardware keyboard drives
/// (the arrows, Home and End, Page Up and Page Down, ⌘A, Esc), shift- and
/// ⌘-click to extend it, "N Messages Selected" in the reader, the context
/// menu for the whole selection, and rows that drag onto a folder. The other
/// is the touch path: a single selection that pushes the reader, with Select
/// mode for several and a per-row context menu. Rows drag on both: onto a
/// folder list wherever one is on screen, and out of the app as an `.eml`
/// (#1681); the touch path's rows from iOS 27 (`touchRowsDrag`).
///
/// Decided by the window's shell rather than the list's own size class. A
/// split column reports a compact size class even on a regular-width iPad, so
/// reading the size class put the iPad list on the iPhone path (#1985). Every
/// shell that shows the list beside its reader is wide; only the tabs, whose
/// list pushes its reader, are not.
enum MessageListLayout {
    static func isWide(in layout: ShellLayout) -> Bool {
        switch layout {
        case .desktop, .split, .ornament: return true
        case .tabs: return false
        }
    }

    /// Whether the touch path's rows drag (#1681). From iOS 27, where a
    /// row's swipe wrapper embeds no `List`: a held press opens the row's
    /// menu and a held press that moves lifts the drag, measured on iOS
    /// 27.1. Below 27 the menu sits in the wrapper's embedded `List` cell,
    /// beside the drag, and that pairing has not been measured, so those
    /// releases keep the touch path's rows still, as before.
    static var touchRowsDrag: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
}
