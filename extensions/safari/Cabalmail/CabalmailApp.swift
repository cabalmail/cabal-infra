// Minimal host app for the Safari Web Extension
// (docs/1.x/browser-extension-plan.md, Phase 8.2): it exists to be
// installable from the Mac App Store and to point the user at Safari's
// extension settings. All real functionality lives in the extension.

import SafariServices
import SwiftUI

@main
struct CabalmailApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 420, minHeight: 300)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    private static let extensionBundleId = "com.cabalmail.extension-host.web-extension"

    @State private var message: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Cabalmail for Safari")
                .font(.title2)
            Text(
                """
                This app installs the Cabalmail Safari extension, which \
                suggests fresh Cabalmail addresses on sign-up forms and opens \
                Cabalmail links in private windows.

                Enable it in Safari's Extensions settings, and turn on \
                "Allow in Private Browsing" so private-link handoff works.
                """
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            Button("Open Safari Extension Settings") {
                SFSafariApplication.showPreferencesForExtension(
                    withIdentifier: Self.extensionBundleId
                ) { error in
                    if let error {
                        Task { @MainActor in
                            message = error.localizedDescription
                        }
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(32)
    }
}
