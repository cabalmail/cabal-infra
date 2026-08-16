import SwiftUI

#if os(iOS)
import UIKit

/// iPadOS-only scene bookkeeping for closing a compose window.
///
/// `dismissWindow()` takes the compose window off screen, but when that
/// window is the frontmost one iPadOS does not activate a sibling scene on
/// its own — it drops the user on the home screen, which reads as a crash
/// (the send keeps running as a background task). Re-activating the main
/// mail scene before the dismissal keeps the app frontmost, so Send / Save
/// Draft / Discard land back on the split view the way the iPhone sheet
/// path does.
///
/// It does *not* retire the compose scene, contrary to what this comment
/// used to claim. Measured on the iPad Pro 11" M5 sim (#1084): after
/// `dismissWindow()` the window's `UISceneSession` is still connected, its
/// whole accessibility subtree is still in the app's tree, and its
/// `ComposeViewModel` + editor `WKWebView` are still alive — for the rest
/// of the process, one set per compose session. Destroying the session
/// explicitly (`requestSceneSessionDestruction`) does not release them
/// either, so the retention sits in `WindowGroup(for:)`'s own
/// presentation bookkeeping rather than in the scene session. Don't wire a
/// remedy here without re-measuring; #1084 records both refuted attempts.
///
/// The main scene has no stable, documented marker among
/// `UIApplication.shared.openSessions` (SwiftUI owns the session
/// configuration), so the main window records its own session here via
/// `recordsMainSceneSession()` and the closing compose window reads it
/// back.
@MainActor
enum MainMailScene {
    /// The main mail window's scene session, recorded by
    /// `recordsMainSceneSession()`. Weak: a discarded scene must not be
    /// kept alive by this bookkeeping.
    static weak var session: UISceneSession?

    /// Brings the main mail scene to the foreground, if one was recorded.
    /// No-op otherwise (e.g. a mailto: cold launch straight into compose —
    /// there is no mail scene to return to).
    static func activate() {
        guard let session else { return }
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(session: session),
            errorHandler: nil
        )
    }
}

/// Empty `UIViewRepresentable` whose only job is to reach the hosting
/// `UIWindowScene` so the main window can record its scene session —
/// the same window-hook trick `ComposeWindowCloseInterceptor` uses on
/// macOS.
private struct MainSceneSessionRecorder: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        // The window isn't attached during makeUIView; defer to the next
        // runloop tick so UIKit has finished wiring the scene host.
        DispatchQueue.main.async { [weak view] in
            if let session = view?.window?.windowScene?.session {
                MainMailScene.session = session
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if let session = uiView.window?.windowScene?.session {
            MainMailScene.session = session
        }
    }
}

extension View {
    /// Records the hosting scene session as the main mail scene so a
    /// closing compose window can re-activate it. Apply on the main
    /// window's root content.
    func recordsMainSceneSession() -> some View {
        background(MainSceneSessionRecorder())
    }
}
#else

extension View {
    /// macOS and visionOS activate a sibling window on their own when a
    /// compose window closes; no scene bookkeeping needed.
    func recordsMainSceneSession() -> some View { self }
}
#endif
