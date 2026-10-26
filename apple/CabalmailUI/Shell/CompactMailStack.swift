import SwiftUI
import CabalmailKit

/// The tab layout's Mail tab: folders, a folder's messages and the reader,
/// in one `NavigationSplitView` that `TabShell`'s compact size-class pin
/// collapses to a stack.
///
/// It has no search model, no feeds and no addresses inspector: the tab bar
/// gives each of those a tab of its own. So its list is always the folder's,
/// never the Search tab's results (#1996); its folder never becomes the
/// Search tab's "This folder only" scope (#1970); and a folder pick here
/// never ends the Search tab's search (#1989). The window's search model
/// belongs to the Search tab and to the wide shells' search field.
///
/// The folder, the open message and the stack's column are the window's
/// (`SceneNavigator`), so a fold or a narrowing hands them to this stack and
/// back.
struct CompactMailStack: View {
    /// The Cabalmail mark in place of the folder list's "Folders" title, at
    /// the tab roots' size (`SidebarBranding.swift`); nil leaves the text.
    let titleMarkSize: CGFloat?

    @Environment(SceneNavigator.self) private var navigator
    /// This stack's identity as one of the window's trees (`TreeGate`).
    @State private var tree = UUID()
    /// How many messages the list has selected: Select mode's "N Messages
    /// Selected" in the reader.
    @State private var listSelectionCount = 0
    /// SPIKE: the split's own width, for SplitShell's column math (#1679).
    @State private var splitWidth: CGFloat = 0
    @AppStorage("cabalmail.layout.listColumnWidth") private var listColumnWidthStored: Double = 360
    @Environment(\.horizontalSizeClass) private var spikeSizeClass

    private var listColumnBounds: (minimum: CGFloat, maximum: CGFloat) {
        guard splitWidth > 0 else { return (ListColumnWidth.minimum, 640) }
        return ListColumnWidth.pinnedBounds(splitWidth: splitWidth)
    }

    private var listColumnWidth: CGFloat {
        min(max(CGFloat(listColumnWidthStored), listColumnBounds.minimum), listColumnBounds.maximum)
    }

    private var readerColumnMinWidth: CGFloat {
        ListColumnWidth.pinnedReaderFloor(splitWidth: splitWidth, listWidth: listColumnWidth)
    }

    private var selectedFolder: Folder? { navigator.folder(in: tree) }
    private var selectedEnvelope: Envelope? { navigator.envelope(in: tree) }

    private var folderSelection: Binding<Folder?> {
        Binding(get: { selectedFolder }, set: { navigator.selectFolder($0) })
    }

    /// The list's selection, through the navigator, which records it. The
    /// stack never searches, so every open message is the folder's.
    private var envelopeSelection: Binding<Envelope?> {
        Binding(
            get: { selectedEnvelope },
            set: { navigator.selectMessage($0, isSearching: false, from: tree) }
        )
    }

    /// Which column the collapsed stack shows. The virtualized message list
    /// is a `ScrollView`, not a `List(selection:)`, so the split view doesn't
    /// push the reader for a tapped row on its own: a selected message shows
    /// `.detail`, a selected folder `.content`, and navigating back drops the
    /// selection (`SceneNavigator.setCompactColumn`).
    private var columnSelection: Binding<NavigationSplitViewColumn> {
        Binding(
            get: { navigator.compactColumn(in: tree) },
            set: { navigator.setCompactColumn($0, isSearching: false, from: tree) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.doubleColumn), preferredCompactColumn: columnSelection) {
            MailSidebarColumn(
                selection: folderSelection,
                titleMarkSize: titleMarkSize,
                // The first load finishes the window's launch landing, or
                // swaps the fetched folder in for a stand-in
                // (`SceneNavigator.foldersLoaded`).
                onFoldersLoaded: { navigator.foldersLoaded($0) },
                header: { EmptyView() }
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                SpikeLog.note("mail.sidebar frame \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))")
            }
        } content: {
            MailContentColumn(
                folder: selectedFolder,
                selection: envelopeSelection,
                onSelectionCountChanged: { listSelectionCount = $0 },
                onSwitchFolder: { navigator.selectFolder($0) },
                header: { EmptyView() }
            )
            .navigationSplitViewColumnWidth(listColumnWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                SpikeLog.note("mail.list frame \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))")
            }
        } detail: {
            MailReaderColumn(
                selectionCount: listSelectionCount,
                envelope: selectedEnvelope,
                sidebarFolder: selectedFolder
            )
            .navigationSplitViewColumnWidth(min: readerColumnMinWidth, ideal: readerColumnMinWidth)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                SpikeLog.note("mail.reader frame \(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            splitWidth = width
            SpikeLog.note("mail.split width \(Int(width)) list=\(Int(listColumnWidth)) floor=\(Int(readerColumnMinWidth))")
        }
        .onChange(of: spikeSizeClass, initial: true) { _, sizeClass in
            SpikeLog.note("mail.stack sizeClass=\(sizeClass == .compact ? "compact" : "regular") tree=\(tree)")
        }
        // Keep the Message menu's commands validated against what they'd
        // actually act on (see `MessageMenuAvailability`).
        .reportsMessageMenuAvailability(
            selectedCount: listSelectionCount,
            hasOpenMessage: selectedEnvelope != nil
        )
        // Switching folders drops any multi-selection with the old mailbox.
        .onChange(of: selectedFolder?.path) {
            listSelectionCount = 0
        }
        // Catch-all drop target behind the stack: a message released
        // anywhere that isn't a folder row is refused, as on the wide shells.
        .dropDestination(for: MessageDragPayload.self) { _, _ in
            false
        }
        // The window's launch landing — or, for a tree a layout swap has
        // just built, the window's route (`SceneNavigator`).
        .task {
            await navigator.mailTreeAppeared(tree, isWide: false)
        }
    }
}
