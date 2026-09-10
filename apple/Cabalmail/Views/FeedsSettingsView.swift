import SwiftUI
import CabalmailKit

/// Settings › Feeds: how the reader marks items read (its own key, distinct
/// from mail's, so the two habits can differ), and OPML import / export
/// for people who reach for Settings before the sidebar's `+` menu.
struct FeedsSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(AppState.self) private var appState
    @State private var management: FeedManagementViewModel?
    @State private var opml = FeedOpmlController()

    var body: some View {
        @Bindable var preferences = preferences
        SettingsForm(title: "Feeds") {
            Section {
                Picker("Mark as read", selection: $preferences.rssMarkAsRead) {
                    Text("Manual").tag(MarkAsReadBehavior.manual)
                    Text("On open").tag(MarkAsReadBehavior.onOpen)
                }
            } footer: {
                Text("Applies to feed items only; mail has its own setting under Reading.")
            }
            Section("Subscriptions") {
                Button {
                    opml.beginImport()
                } label: {
                    Label("Import OPML…", systemImage: "square.and.arrow.down")
                }
                .disabled(management == nil)
                .accessibilityIdentifier("feeds.settings.import")
                Button {
                    guard let management else { return }
                    Task { await opml.beginExport(management: management) }
                } label: {
                    Label("Export OPML…", systemImage: "square.and.arrow.up")
                }
                .disabled(management == nil)
                .accessibilityIdentifier("feeds.settings.export")
            }
        }
        .feedOpmlFlows(opml, management: management)
        .task {
            guard management == nil, let client = appState.client else { return }
            management = FeedManagementViewModel(client: client)
        }
    }
}
