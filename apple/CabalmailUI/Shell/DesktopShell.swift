#if os(macOS)
import SwiftUI
import CabalmailKit

/// The Mac main window's shell: a three-column split with a tiled sidebar.
///
/// What the columns show is shared with the iPad split (`WideMail`, and the
/// columns in `Shell/Columns/`). This shell owns the Mac's chrome: the
/// sidebar stays visible and is headed by the Cabalmail mark; the columns
/// keep their native dividers, bounded and remembered by the width policies;
/// the global search field rides the window's toolbar above the list
/// (`GlobalSearchFieldPlacement`), sized to the list column; and the reader
/// reserves its toolbar slots while it shows a placeholder. Settings is its
/// own scene (⌘,).
///
/// `.id(...)` on the lists and readers (in the shared columns) forces SwiftUI
/// to rebuild each when the selection changes, so its one-shot `.task`
/// re-fires for the new folder or message.
struct DesktopShell: View {
    @Environment(SceneNavigator.self) private var navigator
    @State private var mailState = WideMailState()
    @FocusState private var searchFieldFocused: Bool
    /// The sidebar stays visible: a `NavigationSplitView` here is
    /// AppKit-backed, with no gesture for a tiled sidebar to conflict with,
    /// and it's a desktop multi-pane window.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Live width of the content (message list) column. The toolbar search
    /// field is sized against it — a toolbar item is laid out outside its
    /// column's clip, so an item wider than the column overhangs into the
    /// neighbouring one instead of being cut. Written through
    /// `recordContentColumnWidth`, which waits out a divider drag.
    @State private var contentColumnWidth: CGFloat = 0
    /// Measured width of the title-switch menu at the leading edge of the
    /// list column's toolbar section (`MessageListView+FolderSwitch`, and
    /// the feed list's scope menu). The toolbar search field is sized against
    /// it (`ToolbarSearchFieldWidth`), so the two can share the section
    /// instead of the field being drawn over the menu. The menu reports on
    /// every mount — the list is re-keyed per folder — and the last report
    /// stands while the search surface (whose leading item is a plain title
    /// of similar size) has the column. Zero until measured.
    @State private var listLeadingToolbarWidth: CGFloat = 0

    private var mail: WideMail {
        WideMail(
            navigator: navigator,
            state: $mailState,
            searchFieldFocus: $searchFieldFocused,
            dismissFolderPanel: {}
        )
    }

    var body: some View {
        let mail = self.mail
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: mail.compactColumnSelection) {
            // The sidebar opens at a readable width and remembers the one the
            // user drags to.
            mail.sidebar(titleMarkSize: nil) {
                // Brand mark at the top of the sidebar, below the
                // traffic-light / toolbar row and above the folder list's
                // header. The sidebar column never showed a title here, so
                // the mark is purely additive.
                HStack {
                    CabalmailMark(size: 90)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.top, 12)
            }
            .sidebarColumnWidthPolicy()
        } content: {
            mail.content(onLeadingToolbarWidthChanged: { listLeadingToolbarWidth = $0 }, header: { EmptyView() })
                // The search field sizes itself against this column (see
                // `ToolbarSearchFieldWidth`); a toolbar item can't measure
                // its own pane, so the pane measures itself here.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    recordContentColumnWidth(newWidth)
                }
                // Global search rides the message-list column (moved from
                // above the reading pane in the #1047 toolbar rework — the
                // results it drives show in this column, and the reader
                // needs its toolbar section for its own buttons), next to
                // the toggle for the trailing addresses inspector.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        toolbarSearchField(mail)
                    }
                    mail.addressInspectorToolbarItem
                }
                // The native divider resizes the column; the policy bounds it
                // so the reading pane can't be starved, and opens it at the
                // width it was last left at (`ListColumnWidth`).
                .listColumnWidthPolicy(splitWidth: mail.splitWidth)
        } detail: {
            // Reserve the reader's toolbar slots with disabled stand-ins
            // while it shows a placeholder, so the list's toolbar (compose,
            // reload) stays anchored above the list pane. Without these the
            // unified toolbar packs the list items at the trailing edge —
            // visually above the empty reader — until a message is picked
            // and the real toolbar shoves them back into place. The stand-in
            // set comes from the same `ReaderToolbarLayout.macToolbar` order
            // the real toolbar draws.
            mail.reader(
                mailPlaceholder: ReaderPlaceholderToolbar(items: EmptyDetailToolbar()),
                feedPlaceholder: ReaderPlaceholderToolbar(items: EmptyFeedDetailToolbar())
            )
        }
        .wideMailBehaviour(mail)
    }

    /// Toolbar host for the search field: a stated width so it right-aligns
    /// cleanly above the message-list column rather than stretching, capped
    /// to the column — less its fixed sibling buttons and the title-switch
    /// menu at the section's leading edge — so it can't overhang into the
    /// neighbouring column or cover the menu (`ToolbarSearchFieldWidth`).
    private func toolbarSearchField(_ mail: WideMail) -> some View {
        mail.searchField
            .frame(width: ToolbarSearchFieldWidth.width(
                columnWidth: contentColumnWidth,
                inspectorPresented: mail.addressInspectorPresented,
                leadingWidth: listLeadingToolbarWidth
            ))
    }

    /// Records the measured content-column width the toolbar search field is
    /// sized against.
    ///
    /// The write waits for the main run loop's default mode. The column is
    /// widened by dragging the split view's divider, which AppKit runs as a
    /// mouse-tracking loop, and NSToolbar loses the section re-layout that a
    /// toolbar item's size change asks for while that loop is running: the
    /// field's hosting view took its new width, but the item's frame — and
    /// the Addresses / Compose / Reload frames after it — stayed where the
    /// launch layout put them, so a field that grew with the column grew
    /// *leftward*, centred on its old frame and over the folder-switch menu,
    /// while the width the drag added sat empty. Measured on macOS 27.0: at
    /// a 300pt column the field was 88pt at x=549 with the last button
    /// ending at x=749; after a drag to 500pt the field was 260pt at x=471
    /// and no button had moved. The same size change made once the loop has
    /// ended re-lays the section out normally (field at x=549, buttons
    /// following it, all inside the column), so the width is applied then:
    /// the field holds its size during the drag and takes the new one on
    /// mouse-up. A `.default`-mode block also waits out a live window
    /// resize, which is the other tracking loop that can change this width,
    /// and that is the right moment for it too.
    private func recordContentColumnWidth(_ width: CGFloat) {
        RunLoop.main.perform(inModes: [.default]) {
            // Foundation declares this block `NS_SWIFT_SENDABLE`, so Swift types it
            // nonisolated and reading or writing the main-actor `@State` inside it is
            // an isolation violation. The block is scheduled on the main run loop, so
            // it does run on the main actor: state that guarantee rather than leaving
            // the compiler to infer it, and trap if it ever stops holding.
            MainActor.assumeIsolated {
                guard contentColumnWidth != width else { return }
                contentColumnWidth = width
            }
        }
    }
}
#endif
