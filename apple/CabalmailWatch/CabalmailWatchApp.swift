import SwiftUI

/// Entry point for the watch companion app.
///
/// Scope is deliberately narrow: the address lifecycle (create / list /
/// revoke) — the one Cabalmail feature that is better on the wrist than
/// anywhere else. Mail reading and compose stay on the other platforms.
@main
struct CabalmailWatchApp: App {
    @State private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    // Arms the WCSession receiver and restores a previously
                    // handed-off session. Idempotent across `.task` re-fires.
                    model.start()
                }
        }
    }
}
