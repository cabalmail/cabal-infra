import SwiftUI
import CabalmailKit

// The launch landing of `MailRootView` (`docs/1.x/resume-session-plan.md`):
// where the split view opens on a cold launch — the resume session's mail
// folder and message, or its feed scope on the wide layouts — how the
// provisional landing is reconciled once the folder list arrives, and the
// cross-device cursor probe that may offer the "pick up where you left off"
// toast. Split out of the main file for the lint caps, like its siblings.
extension MailRootView {
    /// The launch `.task`'s landing. A navigate request can be parked before
    /// this view exists — cold launch from a tapped push notification routes
    /// as soon as the session is wired, which precedes the first render, so
    /// the `.onChange` in `body` never fires for it; draining it here also
    /// pre-empts the session landing below (and with it the sidebar's launch
    /// reconcile).
    func landAtLaunch() async {
        if let coordinator = appState.navCoordinator,
           let request = coordinator.navigateRequest {
            coordinator.navigateRequest = nil
            coordinator.scheduleRestore(for: request)
            if selectedFolder?.path != request.folder {
                selectedFolder = Folder(path: request.folder)
            }
            // This *is* the landing: a later re-appearance with a cleared
            // selection must not run the session landing on top of it.
            didProvisionalLand = true
        }
        // Resume where this install left off (`docs/1.x/resume-session-
        // plan.md`). A session that ended in the feed reader — which the
        // wide layouts host in this split view — reopens its scope (and,
        // via `FeedNavigationModifier`, its item) with no mail landing at
        // all. Otherwise land provisionally on the session's mail folder
        // (INBOX when there is none) immediately — before the folder list
        // returns — so the message list (and its on-disk envelope cache)
        // starts loading without waiting on `/list_folders`, and schedule
        // the open message for the list to reselect after its initial
        // load. The message machinery only needs the path; the sidebar's
        // first `onFoldersLoaded` swaps in the fetched folder (or falls
        // back to INBOX if it's gone) and probes the cross-device cursor
        // (`finishLaunchLanding`). Seeded as subscribed so the list
        // doesn't flash the unsubscribed-folder banner before the real
        // subscription state arrives; gated on a wired client because the
        // list's one-shot `.task` can't create its model without one.
        if !didProvisionalLand, selectedFolder == nil, selectedFeedScope == nil,
           let coordinator = appState.navCoordinator, appState.client != nil {
            didProvisionalLand = true
            if isWideSidebar, coordinator.launchSection == .feeds,
               let scope = await coordinator.consumeFeedsLaunchTarget() {
                feedSidebarSelection.wrappedValue = scope
            } else {
                let target = coordinator.mailLaunchTarget()
                awaitingLaunchReconcile = true
                coordinator.armProvisionalLanding()
                if let restore = target.messageRestore {
                    coordinator.scheduleRestore(for: restore)
                }
                selectedFolder = Folder(path: target.folderPath, isSubscribed: true)
            }
        }
    }

    /// Completes the launch mail landing once the folder list arrives. The
    /// launch `.task` has usually already selected a provisional
    /// `Folder(path:)` for the session's folder so the message list didn't
    /// wait on `/list_folders`; here the fetched folder of the same path is
    /// swapped into the selection — `Folder` equality spans attributes/
    /// subscription, and the sidebar's row highlight only matches once the
    /// tag values agree. Same path, so the mounted list
    /// (`.id(selectedFolder.path)`) survives untouched and the same-path guard
    /// on `.onChange` keeps the swap from clearing state. A folder that no
    /// longer exists (deleted since the session was saved, perhaps from
    /// another device) falls back to INBOX and drops the message restore
    /// aimed at it. Then — in the background — probe the server cursor and,
    /// if another install has moved on to a still-reachable position, offer
    /// the "pick up where you left off" toast rather than jumping there.
    /// Tapping it drives the same `navigateRequest` path as the foreground
    /// cross-device resume. The landing's own cursor write is held back
    /// (`armProvisionalLanding`) so the probe reads the other install's
    /// cursor rather than this launch's; it is written once the probe
    /// returns empty (`materializeLanding`).
    func finishLaunchLanding(from folders: [Folder]) {
        let inbox = folders.first { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        } ?? folders.first
        let coordinator = appState.navCoordinator
        if let current = selectedFolder {
            // Provisional landing already on screen (or a navigate request
            // from a push-notification launch moved the selection; a same-
            // path swap is harmless for it too).
            if let fetched = folders.first(where: { $0.path == current.path }) {
                selectedFolder = fetched
            } else if let inbox {
                coordinator?.clearPendingRestore()
                selectedFolder = inbox
            }
        } else if let coordinator {
            // The client wasn't wired when the launch task ran, so there was
            // no provisional landing: land now.
            let target = coordinator.mailLaunchTarget()
            coordinator.armProvisionalLanding()
            if let restore = target.messageRestore {
                coordinator.scheduleRestore(for: restore)
            }
            selectedFolder = folders.first(where: { $0.path == target.folderPath }) ?? inbox
        } else {
            selectedFolder = inbox
        }
        let landedPath = selectedFolder?.path
        Task {
            let candidate = await coordinator?.launchResumeCandidate(folders: folders)
            // If the user already navigated elsewhere while the probe ran,
            // leave them be rather than surfacing a now-stale prompt.
            guard let landedPath, selectedFolder?.path == landedPath else { return }
            if let candidate {
                appState.showToast(
                    .resumeNavigation(folderName: Folder(path: candidate.folder).name, cursor: candidate),
                    duration: 10
                )
            } else {
                coordinator?.materializeLanding()
            }
        }
    }

    /// The launch-time cross-device probe on its own, for launches that had
    /// no mail landing to finish (the feed reader, a parked navigate
    /// request). Offers the toast if another install's cursor is reachable.
    func offerForeignCursorAtLaunch(from folders: [Folder]) {
        Task {
            guard let candidate = await appState.navCoordinator?.launchResumeCandidate(folders: folders) else {
                return
            }
            appState.showToast(
                .resumeNavigation(folderName: Folder(path: candidate.folder).name, cursor: candidate),
                duration: 10
            )
        }
    }
}
