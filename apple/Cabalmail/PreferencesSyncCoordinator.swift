import Foundation
import CabalmailKit

/// Syncs the user's app `Preferences` to the server so a setting changed on one
/// Apple client shows up the next time they sign in on another. The settings
/// are stored per Cognito user (the `app` map on the `cabal-user-preferences`
/// row, behind `/get_preferences` / `/set_preferences`), which anchors them to
/// the Cabalmail login rather than the Apple ID. This is the ONLY sync path:
/// the local `PreferenceStore` is device-local `UserDefaults`, account-scoped
/// (see `Preferences.activate`), and never touches iCloud.
///
/// Created by `AppState` when a client is wired (sign-in or restore) and torn
/// down on sign-out. `@MainActor` because it drives the main-actor-isolated
/// `Preferences` and is invoked from SwiftUI lifecycle hooks.
///
/// Lifecycle:
/// - **Start** (`start`): fetch the server copy once and apply it — the server
///   wins on login — then observe local edits via `Preferences.onLocalChange`.
/// - **Local edit**: debounce, then push the complete `app` map (every key
///   this build knows). The server merges per key, so concurrent multi-device
///   edits are last-write-wins per key, and a key introduced by a newer
///   client build survives a push from an older one.
/// - **Foreground** (`reconcile`): re-fetch and re-apply so a change made on
///   another device mid-session lands, unless a local edit is still pending
///   (never clobber an edit we haven't managed to push yet).
@MainActor
final class PreferencesSyncCoordinator {
    private let client: CabalmailClient
    private let preferences: Preferences

    private var saveTask: Task<Void, Never>?
    /// The map last confirmed in sync with the server (fetched or pushed), so a
    /// no-op edit or a redundant reconcile doesn't trigger a write.
    private var lastSynced: [String: String]?
    /// True from a local edit until its push succeeds — reconcile skips the
    /// server pull while set so an in-flight local change isn't overwritten.
    private var pendingLocalChange = false
    /// Debounce window for pushes: a quick flurry of toggles collapses to one
    /// write. Matches `NavStateCoordinator`'s cursor-save cadence.
    private let saveDebounce: Duration = .seconds(1)
    /// Set by `stop()`. `start()`/`reconcile()` run their server pull as a
    /// detached task the caller doesn't hold, so sign-out can land while a
    /// fetch is in flight; without this guard the late response would apply
    /// the *previous* account's settings into whatever scope `Preferences`
    /// has activated by then — the cross-account leak, resurrected.
    private var stopped = false

    init(client: CabalmailClient, preferences: Preferences) {
        self.client = client
        self.preferences = preferences
    }

    /// Applies the server copy (server wins on login) and starts observing
    /// local edits. Safe to call once per wired session.
    func start() async {
        await pullFromServer()
        // A sign-out during the pull above must not re-attach the observer
        // (`stop()` already detached it for good).
        guard !stopped else { return }
        preferences.onLocalChange = { [weak self] in
            self?.scheduleSave()
        }
    }

    /// Detaches the local-edit observer, cancels any pending push, and marks
    /// the coordinator dead so an in-flight server pull is discarded instead
    /// of applied. Called on sign-out before the coordinator is released.
    func stop() {
        stopped = true
        saveTask?.cancel()
        saveTask = nil
        preferences.onLocalChange = nil
    }

    /// Re-pulls the server copy on foreground so a change made elsewhere lands
    /// mid-session. Skips while a local edit is still pending its push, so the
    /// user's own unsaved change always wins over a stale server value.
    func reconcile() async {
        guard !pendingLocalChange else { return }
        await pullFromServer()
    }

    /// Fetches the server's `app` map and applies it. A missing/empty map (the
    /// user has never synced) leaves the local defaults in place.
    private func pullFromServer() async {
        guard let remote = try? await client.fetchAppPreferences(), !remote.isEmpty else { return }
        // The fetch may have raced a sign-out; this account's values must
        // not land in the next account's (already re-activated) scope.
        guard !stopped else { return }
        preferences.applyRemote(remote)
        // Record the applied set so the value we just wrote in doesn't read as
        // a local edit and echo straight back out.
        lastSynced = preferences.appPreferencesPayload()
    }

    private func scheduleSave() {
        let payload = preferences.appPreferencesPayload()
        // Applying a server pull can fire the observer via the store write;
        // skip when nothing actually changed relative to the last sync.
        if payload == lastSynced { return }
        pendingLocalChange = true
        saveTask?.cancel()
        let debounce = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.push(payload)
        }
    }

    private func push(_ payload: [String: String]) async {
        do {
            try await client.saveAppPreferences(payload)
            lastSynced = payload
            pendingLocalChange = false
        } catch {
            // Best-effort: a failed push is never worth surfacing. The next
            // edit reschedules, and the next sign-in / foreground reconciles
            // from whatever did persist.
        }
    }
}
