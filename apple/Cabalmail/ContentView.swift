import SwiftUI
import CabalmailKit

/// Phase 1 placeholder. Replaced by real navigation in Phase 4.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("Hello, Cabalmail")
                .font(.title)
            Text("Build \(CabalmailKit.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
