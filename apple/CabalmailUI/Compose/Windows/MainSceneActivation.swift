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
/// configuration), so each main window records its own session here, under
/// its window identity, via `recordsMainSceneSession()`. A closing compose
/// window reads back the window it came from, and a tapped notification
/// the window its scene belongs to.
@MainActor
enum MainMailScene {
    /// Each main window's scene session, by window. Weak: a discarded scene
    /// must not be kept alive by this bookkeeping.
    private static var sessions = WindowRegistry<UISceneSession>()

    /// Records `session` as `window`'s.
    static func register(_ session: UISceneSession, for window: UUID) {
        sessions.register(session, for: window)
    }

    /// Forgets `window`, while it still holds `session`.
    static func remove(_ window: UUID, holding session: UISceneSession?) {
        sessions.remove(window, holding: session)
    }

    /// The main window whose scene is `session`: where a notification the
    /// system showed over that scene opens. Nil for a compose scene, or a
    /// main window that has not recorded itself yet.
    static func window(for session: UISceneSession?) -> UUID? {
        sessions.window(holding: session)
    }

    /// Brings a main mail scene to the foreground: `window`'s, else
    /// `fallback`'s, else the one recorded last. With no recorded session —
    /// a mailto: cold launch straight into compose, or a compose window that
    /// outlived the mail scene it was opened from — it asks for a new
    /// application-role scene instead, which SwiftUI serves from the first
    /// `WindowGroup`, the mail window. The compose window then has somewhere
    /// to land: `dismissWindow()` cannot dismiss an app's last scene on iOS,
    /// so without this a lone compose window shrugged off Cancel and Send
    /// alike (#1688).
    static func activate(_ window: UUID? = nil, fallback: UUID? = nil) {
        let request: UISceneSessionActivationRequest
        if let session = sessions.value(for: window) ?? sessions.value(for: fallback) ?? sessions.latest {
            request = UISceneSessionActivationRequest(session: session)
        } else {
            request = UISceneSessionActivationRequest(role: .windowApplication)
        }
        UIApplication.shared.activateSceneSession(for: request, errorHandler: nil)
    }
}

/// Empty `UIViewRepresentable` whose only job is to reach the hosting
/// `UIWindowScene` so the main window can record its scene session under
/// its window identity — the same window-hook trick
/// `ComposeWindowCloseInterceptor` uses on macOS.
private struct MainSceneSessionRecorder: UIViewRepresentable {
    let window: UUID?

    @MainActor
    final class Coordinator {
        var window: UUID?
        weak var session: UISceneSession?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let coordinator = context.coordinator
        coordinator.window = window
        // The window isn't attached during makeUIView; defer to the next
        // runloop tick so UIKit has finished wiring the scene host.
        DispatchQueue.main.async { [weak view] in
            Self.record(view?.window?.windowScene?.session, in: coordinator)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.window = window
        Self.record(uiView.window?.windowScene?.session, in: context.coordinator)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let window = coordinator.window {
            MainMailScene.remove(window, holding: coordinator.session)
        }
    }

    private static func record(_ session: UISceneSession?, in coordinator: Coordinator) {
        if let session, let window = coordinator.window {
            coordinator.session = session
            MainMailScene.register(session, for: window)
        }
    }
}

/// Hands the recorder the window identity `mainWindowCommandScope` gives
/// this window.
private struct MainSceneSessionRecording: View {
    @Environment(\.commandWindowID) private var window

    var body: some View {
        MainSceneSessionRecorder(window: window)
    }
}

extension View {
    /// Records the hosting scene session as the main mail scene so a
    /// closing compose window can re-activate it. Apply on the main
    /// window's root content.
    public func recordsMainSceneSession() -> some View {
        background(MainSceneSessionRecording())
    }
}
#else

extension View {
    /// macOS and visionOS activate a sibling window on their own when a
    /// compose window closes; no scene bookkeeping needed.
    public func recordsMainSceneSession() -> some View { self }
}
#endif
