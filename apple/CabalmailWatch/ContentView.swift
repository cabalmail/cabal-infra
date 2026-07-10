import CabalmailKit
import SwiftUI

/// Placeholder root view for the target-scaffolding phase. The next phases
/// replace this with the WatchConnectivity credential bootstrap and the
/// address list / create / revoke screens.
struct ContentView: View {
    /// Deliberate CabalmailKit reference: forces the package to link into
    /// the watch binary, so this scaffold proves kit portability at link
    /// time rather than only at typecheck time.
    private static let kitLinkProbe = String(describing: Address.self)

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Cabalmail")
                .font(.headline)
            Text("Address management is on its way.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ContentView()
}
