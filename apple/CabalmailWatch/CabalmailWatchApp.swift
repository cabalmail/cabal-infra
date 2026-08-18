import CabalmailKit
import SwiftUI

/// Entry point for the watch companion app.
///
/// Scope is deliberately narrow: the address lifecycle (create / list /
/// revoke) — the one Cabalmail feature that is better on the wrist than
/// anywhere else. Mail reading and compose stay on the other platforms.
@main
struct CabalmailWatchApp: App {
    @State private var model = WatchAppModel()
    @State private var relay = WatchSessionRelay()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task {
                    // Arms the WCSession receiver, then restores a previously
                    // handed-off session. Both are idempotent across `.task`
                    // re-fires. The receiver lives in this target because
                    // WatchConnectivity has no macOS surface (#1124).
                    relay.activate(model: model)
                    model.start()
                }
        }
    }
}
