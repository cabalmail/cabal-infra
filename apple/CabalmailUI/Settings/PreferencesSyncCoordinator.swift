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
///   The one exception is a change an earlier session could not send
///   (`Preferences.hasUnsentChanges`, kept on disk): it is pushed first, and
///   the pull waits until it has gone, since the pull would overwrite it.
/// - **Local edit**: debounce, then push the complete `app` map (every key
///   this build knows). The server merges per key, so concurrent multi-device
///   edits are last-write-wins per key, and a key introduced by a newer
///   client build survives a push from an older one.
/// - **A failed push** stays unsent and goes again when the connection
///   returns, on return to the foreground, at the next session's start, and
///   when the feed queue asks before it drops a flag add the server refused
///   (`RssSyncEngine.setUnsentSettingsPush`): a flag created while the push
///   was failing is in this device's palette and not yet the server's
///   (#2421). Each retry sends the settings as they are then.
/// - **A refused push** (a 400: the server does not take a value in the
///   map) is not sent again while the settings are still that map, since
///   it would be refused again; the next settings change sends again, and
///   so does the next session's start. It stays unsent meanwhile, and the
///   pull stays held, so nothing the user changed is lost (#2439).
/// - **An edit made while a push is out** is not in that push. When the
///   push lands, the settings as they are then go in another, at once
///   (#2440).
/// - **Foreground** (`reconcile`): send a change still unsent, then re-fetch
///   and re-apply so a change made on another device mid-session lands. A
///   pull never lands over a change that has not reached the server.
@MainActor
public final class PreferencesSyncCoordinator {
    private let client: CabalmailClient
    private let preferences: Preferences

    private var saveTask: Task<Void, Never>?
    /// The push in flight; whoever else asks for one waits on it.
    private var pushing: Task<Bool, Never>?
    /// The map the server last refused, for this session only: no trigger
    /// sends it again until the settings change.
    private var refused: [String: String]?
    /// Follows the connection while the session runs (`observeConnection`).
    private var connectionTask: Task<Void, Never>?
    /// What `observeConnection` follows: a test's stream, or nil for the
    /// client's own reachability.
    private let connection: AsyncStream<Bool>?
    /// The map last confirmed in sync with the server (fetched or pushed), so a
    /// no-op edit or a redundant reconcile doesn't trigger a write.
    private var lastSynced: [String: String]?
    /// Debounce window for pushes: a quick flurry of toggles collapses to one
    /// write. Matches `NavStateCoordinator`'s cursor-save cadence.
    private let saveDebounce: Duration
    /// Set by `stop()`. `start()`/`reconcile()` run their server pull as a
    /// detached task the caller doesn't hold, so sign-out can land while a
    /// fetch is in flight; without this guard the late response would apply
    /// the *previous* account's settings into whatever scope `Preferences`
    /// has activated by then — the cross-account leak, resurrected. A push
    /// that outlives the session must not clear the unsent mark either:
    /// by then it is the next account's.
    private var stopped = false

    /// True from a local edit until the server has taken it, kept on disk
    /// beside the account's settings so a relaunch still sends it.
    private var hasUnsentChange: Bool {
        get { preferences.hasUnsentChanges }
        set { preferences.hasUnsentChanges = newValue }
    }

    /// `connection` replaces the client's reachability, for tests; the
    /// feed queue's question is answered from the moment this exists, so
    /// the session's first drain already asks it.
    init(
        client: CabalmailClient,
        preferences: Preferences,
        connection: AsyncStream<Bool>? = nil,
        saveDebounce: Duration = .seconds(1)
    ) {
        self.client = client
        self.preferences = preferences
        self.connection = connection
        self.saveDebounce = saveDebounce
        client.rssSync?.setUnsentSettingsPush { [weak self] in
            await self?.sendUnsentForFeedQueue() ?? .nothingUnsent
        }
    }

    /// Applies the server copy (server wins on login) and starts observing
    /// local edits. Safe to call once per wired session.
    func start() async {
        // A change an earlier session could not send goes before the pull,
        // which would otherwise put the server's older values over it.
        let nothingUnsent = hasUnsentChange ? await pushUnsent() : true
        if nothingUnsent {
            await pullFromServer()
        }
        // A sign-out during the pull above must not re-attach the observer
        // (`stop()` already detached it for good).
        guard !stopped else { return }
        preferences.onLocalChange = { [weak self] in
            self?.scheduleSave()
        }
        observeConnection()
    }

    /// Detaches the local-edit observer, cancels any pending push, and marks
    /// the coordinator dead so an in-flight server pull is discarded instead
    /// of applied. Called on sign-out before the coordinator is released.
    /// A change still unsent stays marked on disk for this account's next
    /// session.
    func stop() {
        stopped = true
        saveTask?.cancel()
        saveTask = nil
        connectionTask?.cancel()
        connectionTask = nil
        preferences.onLocalChange = nil
        client.rssSync?.setUnsentSettingsPush(nil)
    }

    /// On return to the foreground: sends a change still unsent, then
    /// re-pulls the server copy so a change made elsewhere lands
    /// mid-session. While a change cannot be sent the pull is skipped, so
    /// the user's own change always wins over a stale server value.
    public func reconcile() async {
        if hasUnsentChange {
            guard await pushUnsent() else { return }
        }
        await pullFromServer()
    }

    /// The feed queue's question when the server has refused a flag add
    /// (`RssUnsentSettings`): sends a settings change still waiting, which
    /// may hold the very flag, and says whether it went.
    func sendUnsentForFeedQueue() async -> RssUnsentSettings {
        guard !stopped, hasUnsentChange else { return .nothingUnsent }
        return await pushUnsent() ? .sent : .stillUnsent
    }

    /// Sends the settings as they are now while a change is unsent; joins a
    /// push already in flight. True once nothing is left unsent.
    @discardableResult
    func pushUnsent() async -> Bool {
        if let pushing { return await pushing.value }
        guard !stopped else { return false }
        guard hasUnsentChange else { return true }
        guard preferences.appPreferencesPayload() != refused else { return false }
        // Main-actor work, like this method: the task clears itself before
        // anyone waiting on it resumes, so no caller joins a finished push.
        let task = Task {
            var outcome = await self.sendNow()
            // An edit made while the push was out (its debounce may have
            // ended then, and joined this push) goes in another, at once.
            while outcome == .changedSince {
                outcome = await self.sendNow()
            }
            self.pushing = nil
            return outcome == .sent
        }
        pushing = task
        return await task.value
    }

    /// How one request of a push went.
    private enum PushOutcome {
        /// The server took the settings, and they have not changed since.
        case sent
        /// The server took them, and they changed while the request was out.
        case changedSince
        /// The request did not reach the server, or the server failed.
        case failed
        /// The server refused the map (a 400).
        case refused
        /// The session ended first.
        case stopped
    }

    private func sendNow() async -> PushOutcome {
        // After `stop()` the settings may already be the next account's.
        guard !stopped else { return .stopped }
        // The settings as they are now, not as they were at the edit: a
        // retry must not send back something changed since.
        let payload = preferences.appPreferencesPayload()
        do {
            try await client.saveAppPreferences(payload)
        } catch CabalmailError.http(status: 400, let body) {
            refused = payload
            CabalmailLog.warn("PreferencesSync", "the server refused the settings; "
                + "they go again once they change: " + body)
            return .refused
        } catch {
            CabalmailLog.warn("PreferencesSync", "settings push failed; it goes again later: "
                + error.localizedDescription)
            return .failed
        }
        guard !stopped else { return .stopped }
        lastSynced = payload
        guard preferences.appPreferencesPayload() == payload else { return .changedSince }
        hasUnsentChange = false
        return .sent
    }

    /// Sends a change still unsent each time the connection comes back.
    /// The stream's first value is the connection as it is when observing
    /// starts, which is not a return: only offline to online counts.
    private func observeConnection() {
        guard connectionTask == nil, let changes = connection ?? reachabilityChanges() else { return }
        connectionTask = Task { [weak self] in
            var wasReachable: Bool?
            for await reachable in changes {
                defer { wasReachable = reachable }
                guard reachable, wasReachable == false else { continue }
                guard let self, !Task.isCancelled else { return }
                await self.pushUnsent()
            }
        }
    }

    private func reachabilityChanges() -> AsyncStream<Bool>? {
        #if canImport(Network)
        return client.reachability?.changes()
        #else
        return nil
        #endif
    }

    /// Fetches the server's `app` map and applies it. A missing/empty map (the
    /// user has never synced) leaves the local defaults in place.
    private func pullFromServer() async {
        guard let remote = try? await client.fetchAppPreferences(), !remote.isEmpty else { return }
        // The fetch may have raced a sign-out; this account's values must
        // not land in the next account's (already re-activated) scope.
        guard !stopped else { return }
        // Nor over an edit made while the fetch was out, which the server
        // has not had yet.
        guard !hasUnsentChange else { return }
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
        hasUnsentChange = true
        saveTask?.cancel()
        let debounce = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.pushUnsent()
        }
    }
}
