import SwiftUI

/// Entry point for the watch companion app.
///
/// Scope is deliberately narrow: the address lifecycle (create / list /
/// revoke) — the one Cabalmail feature that is better on the wrist than
/// anywhere else. Mail reading and compose stay on the other platforms.
@main
struct CabalmailWatchApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
