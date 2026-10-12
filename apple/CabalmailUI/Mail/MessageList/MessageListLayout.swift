/// Which of its two paths the message list takes on a window's layout.
///
/// The wide path is the Mac's: a multi-selection the hardware keyboard drives
/// (the arrows, Home and End, Page Up and Page Down, ⌘A, Esc), shift- and
/// ⌘-click to extend it, "N Messages Selected" in the reader, the context
/// menu for the whole selection, and rows that drag onto a folder. The other
/// is the touch path: a single selection that pushes the reader, with Select
/// mode for several and a per-row context menu.
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
}
