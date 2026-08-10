import SwiftUI

/// The loading / error / loaded scaffold shared by the screens that fetch
/// their contents in a `.task` and own the three states themselves.
///
/// Each of those screens kept its own copy of the same three branches: a
/// full-frame `ProgressView` while the load runs, a centered message with a
/// bordered Retry button if it failed, and the real content otherwise. The
/// copies had drifted to differ only in the progress label, so they live here
/// instead — the failure surface (glyph, red tint, spacing, Retry wording) is
/// the same in every one, and stays that way by construction.
///
/// `retry` is the caller's own reload closure, invoked as-is: the owning view
/// keeps its `isLoading` / `errorMessage` state and its loader, and this view
/// only decides which of the three to show.
///
/// This is not the only error presentation in the app, and deliberately so.
/// Screens that surface an error *beside* their content rather than instead of
/// it — the address and folder lists, compose, the message list — render an
/// inline `Label` with no retry, and the reader's body pane offers a retry that
/// disables itself mid-load. Those aren't this scaffold and shouldn't be routed
/// through it.
struct AsyncContentView<Content: View>: View {
    let isLoading: Bool
    let loadingLabel: LocalizedStringKey
    let errorMessage: String?
    let retry: () -> Void
    @ViewBuilder let content: () -> Content

    @ViewBuilder
    var body: some View {
        if isLoading {
            ProgressView(loadingLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content()
        }
    }
}
