import SwiftUI

/// The Feeds menu (macOS menu bar; the iPadOS hardware-keyboard menu picks
/// it up from the same declaration). Commands dispatch through
/// `AppState.requestFeedCommand`, and the mounted feed sidebar answers them
/// through `FeedManagementSheets`, the same tick pattern the Mailbox and
/// Message menus use. Dimmed while signed out: nothing is there to answer.
struct FeedsMenuCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Feeds") {
            Button("Subscribe to Feed…") { appState.requestFeedCommand(.subscribe) }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!available)
            Button("New Feed Folder…") { appState.requestFeedCommand(.newFolder) }
                .disabled(!available)
            Divider()
            Button("Import OPML…") { appState.requestFeedCommand(.importOpml) }
                .disabled(!available)
            Button("Export OPML…") { appState.requestFeedCommand(.exportOpml) }
                .disabled(!available)
            Divider()
            Button("Refresh Feeds") { appState.requestFeedCommand(.refresh) }
                .disabled(!available)
        }
    }

    private var available: Bool { appState.status == .signedIn }
}
