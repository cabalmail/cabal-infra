import SwiftUI

@main
struct CabalmailMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        Settings {
            Text("Settings placeholder")
                .padding()
        }
        #endif
    }
}
