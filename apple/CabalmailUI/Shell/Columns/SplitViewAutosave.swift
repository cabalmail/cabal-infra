#if os(macOS)
import AppKit
import SwiftUI

/// Keeps AppKit's saved divider positions from overriding the widths the
/// main window's columns remember for themselves (`SidebarColumnWidth`,
/// `ListColumnWidth`).
///
/// SwiftUI gives the main window's `NavigationSplitView` an autosave name
/// (`main-AppWindow-1, SidebarNavigationSplitView`), so AppKit saves the
/// columns' frames under `NSSplitView Subview Frames <name>` on every divider
/// move and puts them back when the next split is built. On macOS 27 that
/// restore breaks the message list. The list column's view runs under the
/// floating sidebar, from the window's leading edge to the list/reader
/// divider, but the frame AppKit saves is the list's own, and the restore
/// gives it to the wider view: measured, a 481pt list beside a 340pt sidebar
/// came back 141pt wide, was pushed up to its 300pt floor, and AppKit then
/// saved the 300. So no list width ever survived a relaunch. With the saved
/// frames gone, both columns open exactly at the preferred width they are
/// given, which is the width each one persisted.
///
/// AppKit has already restored by the time a column's views reach the window,
/// so the frames have to be gone before the window is built:
/// `clearSavedFrames` runs at launch. The split then stops writing them
/// (`SplitViewAutosaveDisabler`), so a split built later in the same session —
/// the main window reopened from the menu-bar item, or rebuilt by signing out
/// and back in — has nothing to restore either.
@MainActor
public enum SplitViewAutosave {
    /// Prefix of the defaults key AppKit saves a split's frames under; the
    /// split's autosave name follows it.
    static let savedFramesKeyPrefix = "NSSplitView Subview Frames "

    /// Removes the frames AppKit saved for the splits of every window in the
    /// `windowGroupID` group. SwiftUI names those windows
    /// `<id>-AppWindow-<n>` (see `MainMailWindow`) and a window's split takes
    /// the window's name, so the group id is the prefix to match; the
    /// Settings window's split is left alone.
    public static func clearSavedFrames(windowGroupID: String, in defaults: UserDefaults = .standard) {
        let prefix = savedFramesKeyPrefix + windowGroupID + "-"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Turns off `split`'s autosave and drops whatever it saved so far.
    static func disable(_ split: NSSplitView, in defaults: UserDefaults = .standard) {
        guard let name = split.autosaveName, !name.isEmpty else { return }
        split.autosaveName = nil
        defaults.removeObject(forKey: savedFramesKeyPrefix + name)
    }

    /// The split view `view` is a column of: the nearest `NSSplitView` above
    /// it. The navigation split sits inside the one `.inspector` adds, so the
    /// first split up from a column's content is always the column's own.
    static func enclosingSplitView(of view: NSView) -> NSSplitView? {
        var ancestor = view.superview
        while let candidate = ancestor {
            if let split = candidate as? NSSplitView { return split }
            ancestor = candidate.superview
        }
        return nil
    }
}

/// Turns off the autosave of the split view whose column it sits in, once it
/// reaches the window. Hung on the message-list column (`ListColumnWidth`).
struct SplitViewAutosaveDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DisablerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DisablerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, let split = SplitViewAutosave.enclosingSplitView(of: self) else { return }
            SplitViewAutosave.disable(split)
        }

        // Sits behind the column's content: never the target of a click,
        // scroll or drop meant for the list.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
