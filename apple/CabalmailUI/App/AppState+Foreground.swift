import SwiftUI
import CabalmailKit

// What the app does as it leaves and returns to the foreground, once per
// app however many main windows are open. Each app entry's scene-level
// `.onChange(of: scenePhase)` calls `appScenePhaseChanged(to:)` with the
// entry's own phase, which is the app's: active while any of its scenes is.
// Before, each main window's root observed that same phase, so every window
// flushed, reconciled and refreshed on the one change.
//
// The cross-device probe is not here: it runs when a main window comes to
// the front, since only a main window can show its offer (see
// `offerCrossDeviceCursor`).
extension AppState {
    /// The app's scene phase changed to `phase`.
    public func appScenePhaseChanged(to phase: ScenePhase) {
        // Leaving the foreground: write the local resume session now, so a
        // debounce in flight isn't lost if the process is terminated while
        // backgrounded.
        if phase != .active { navCoordinator?.flushSession() }
        guard phase == .active else { return }
        // Pick up settings changed on another device while the app was in
        // the background (server wins, unless a local edit is still pending
        // its push).
        Task { await prefsCoordinator?.reconcile() }
        // Feeds: fresh items and the offline mutation queue.
        Task { await refreshFeedsOnForeground() }
    }

    /// The cross-device "pick up where you left off" probe (resume-session
    /// plan, Phase C): at launch, and each time a main window returns to the
    /// front. One at a time for the app: windows coming forward together
    /// ask the server once, and a window that mounts while another's launch
    /// probe is out adds nothing to it. The offer is a toast every main
    /// window shows; the one whose Resume is tapped moves.
    func offerCrossDeviceCursor(atLaunch: Bool) async {
        guard let coordinator = navCoordinator, !isOfferingCrossDeviceCursor else { return }
        isOfferingCrossDeviceCursor = true
        defer { isOfferingCrossDeviceCursor = false }
        let candidate = atLaunch
            ? await coordinator.launchResumeCandidate()
            : await coordinator.foreignCursorOnForeground()
        guard let candidate else { return }
        let title = await coordinator.resumeTitle(for: candidate)
        showToast(.resumeNavigation(folderName: title, cursor: candidate), duration: 10)
    }
}
