import SwiftUI

#if os(macOS)
import AppKit

/// macOS-only delegate that intercepts the standard red close button on the
/// compose window so it raises the "Discard draft?" dialog. Without this,
/// clicking the close button (or hitting Cmd+W) bypasses the confirmation
/// entirely and the user gets no chance to save the draft before the window
/// disappears.
///
/// It asks the *same* question the toolbar Cancel button asks: since #1094
/// that question is only worth putting to the user when there is a draft to
/// decide about, and since #1106 this path resolves it the same way. That
/// works because `windowShouldClose` declines the close and returns `false`,
/// so `onCloseAttempt` runs after the close has already been deferred and
/// may await the WebKit bridge before deciding — hence its `async` type.
///
/// The coordinator is held as `@State` by `ComposeView` and re-bound to the
/// hosting `NSWindow` via `ComposeWindowCloseInterceptor` (an
/// `NSViewRepresentable` that walks up to the parent window). The dialog's
/// Save Draft / Discard buttons set `allowsClose = true` before triggering
/// the model's close action so the second `windowShouldClose` call (the
/// one that comes from `dismissWindow()`) returns true instead of looping
/// back into the dialog.
@MainActor
final class ComposeWindowCloseCoordinator: NSObject, NSWindowDelegate {
    /// Called from `windowShouldClose` when the user attempts a close and
    /// the action hasn't been pre-approved. `ComposeView` binds this to
    /// `cancelOrAsk()`, the same routine the toolbar Cancel button runs.
    ///
    /// `async` because that routine has to ask the WebKit bridge whether
    /// anything was typed before it knows whether the dialog is worth
    /// raising. The close is already declined by the time this runs, so the
    /// window simply stays up for the round trip (#1106).
    var onCloseAttempt: (@MainActor () async -> Void)?
    /// Set true by the dialog buttons (or by `send()` succeeding) before
    /// they invoke the model's close action, so the close call that comes
    /// next isn't intercepted. One-shot — the coordinator is thrown away
    /// with the scene.
    var allowsClose: Bool = false

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowsClose { return true }
        // Decline first, decide after. AppKit gets its answer on this turn
        // of the runloop; the handler is free to suspend, and whatever it
        // settles on either raises the dialog or closes the window itself.
        guard let onCloseAttempt else { return false }
        Task { await onCloseAttempt() }
        return false
    }
}

/// Empty `NSViewRepresentable` whose only job is to give us a hook into
/// the hosting `NSWindow` so we can attach the close coordinator as its
/// delegate. SwiftUI doesn't surface the window directly, but a child
/// `NSView` in a `.background` modifier gets one as soon as it enters the
/// view hierarchy.
struct ComposeWindowCloseInterceptor: NSViewRepresentable {
    let coordinator: ComposeWindowCloseCoordinator

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window isn't attached during makeNSView; defer to the next
        // runloop tick so AppKit has finished wiring the scene host.
        DispatchQueue.main.async { [weak view, coordinator] in
            view?.window?.delegate = coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window, window.delegate !== coordinator else { return }
        window.delegate = coordinator
    }
}
#endif
