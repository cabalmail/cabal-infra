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
                    guard error != nil else { return }
                    // SFErrorNoExtensionFound (code 1) is the common case:
                    // Safari has not registered the extension yet, which is
                    // the normal state for a first run of an unsigned dev
                    // build before Develop > Allow Unsigned Extensions is
                    // on. The deep link cannot work until Safari lists the
                    // extension, so open Safari and explain the manual path
                    // instead of surfacing a raw error-domain string.
                    Task { @MainActor in
                        message = """
                        Safari hasn't registered the extension yet. Open \
                        Safari > Settings > Extensions and enable Cabalmail \
                        there. For unsigned development builds, first turn \
                        on Develop > Allow Unsigned Extensions, then \
                        relaunch this app.
                        """
                    }
                    if let safari = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.Safari"
                    ) {
                        NSWorkspace.shared.openApplication(
                            at: safari,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(32)
    }
}
