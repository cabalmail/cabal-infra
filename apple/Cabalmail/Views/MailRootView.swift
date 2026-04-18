import SwiftUI
import CabalmailKit

/// Root of the signed-in navigation.
///
/// - iPhone (compact horizontal size class): a `NavigationStack` that
///   pushes folder → messages → detail.
/// - iPad / macOS / visionOS (regular size class): a three-column
///   `NavigationSplitView`. Selections are lifted to `@State` here so the
///   sibling columns stay in sync.
struct MailRootView: View {
    @State private var selectedFolder: Folder?
    @State private var selectedEnvelope: Envelope?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        #if os(iOS)
        if horizontalSizeClass == .regular {
            splitView
        } else {
            stackView
        }
        #else
        splitView
        #endif
    }

    private var splitView: some View {
        NavigationSplitView {
            FolderListView(selection: $selectedFolder)
        } content: {
            if let selectedFolder {
                MessageListView(folder: selectedFolder, selection: $selectedEnvelope)
            } else {
                ContentUnavailableView(
                    "Select a folder",
                    systemImage: "sidebar.left",
                    description: Text("Pick a mailbox from the sidebar to browse messages.")
                )
            }
        } detail: {
            if let selectedFolder, let selectedEnvelope {
                MessageDetailView(folder: selectedFolder, envelope: selectedEnvelope)
            } else {
                ContentUnavailableView(
                    "No message selected",
                    systemImage: "envelope",
                    description: Text("Pick a message from the list to read it.")
                )
            }
        }
    }

    private var stackView: some View {
        NavigationStack {
            FolderListView(selection: $selectedFolder)
                .navigationDestination(for: Folder.self) { folder in
                    MessageListView(folder: folder, selection: $selectedEnvelope)
                        .navigationDestination(for: Envelope.self) { envelope in
                            MessageDetailView(folder: folder, envelope: envelope)
                        }
                }
        }
    }
}
