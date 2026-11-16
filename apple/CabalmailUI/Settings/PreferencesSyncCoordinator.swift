import Foundation
import CabalmailKit

/// Syncs the user's app `Preferences` to the server so a setting changed on one
/// Apple client shows up on another. The settings are stored per Cognito user
/// (the `app` map on the `cabal-user-preferences` row, behind
/// `/get_preferences` / `/set_preferences`), which anchors them to the
/// Cabalmail login rather than the Apple ID. This is the ONLY sync path: the
/// local `PreferenceStore` is device-local `UserDefaults`, account-scoped (see
/// `Preferences.activate`), and never touches iCloud. The server's side of
/// the contract is `docs/settings-sync.md`.
///
/// Created by `AppState` when a client is wired (sign-in or restore) and torn
/// down on sign-out. `@MainActor` because it drives the main-actor-isolated
/// `Preferences` and is invoked from SwiftUI lifecycle hooks.
///
/// The rule it keeps: **a device sends only what was changed on it, and says
/// which version of the row it was built on.** `Preferences` records the keys
/// a user's edit changed (`hasUnsentChanges`, kept on disk); this class makes
/// the requests.
///
/// - **A pull** (`start`, and `reconcile` on return to the foreground) takes
///   the server's value for every key this device has not changed, and leaves
///   the changed ones alone, so it never waits for a push. An answer older
///   than the row already held is dropped.
/// - **A push** carries the unsent keys only, never the whole map, with the
///   row's version as this device last saw it. It goes a debounce after a
///   local edit, and again when the connection returns, at a pull, and when
///   the feed queue asks before it drops a flag add the server refused
///   (`RssSyncEngine.setUnsentSettingsPush`, #2421). One push is out at a
///   time; whoever asks meanwhile waits on it, and it sends again, at once,
///   for an edit made while a request was out (#2440).
/// - **Nothing is sent before this device has read the row.** A device new to
///   the account holds defaults, not the account's settings (#2452).
/// - **The server refuses a push built on an older row** (a 409, carrying
///   the row as it is). The row is taken as a pull is, the flag list merged
///   with this device's when both changed it, and the push goes again on the
///   new version (#2464).
/// - **A failed push** (no connection, a server error) stays unsent and goes
///   again at the next trigger.
/// - **A refused push** (a 400: the server does not take a value in it) is
///   not sent again while the unsent keys still hold those values, since it
///   would be refused again (#2439). It goes again once one of them changes,
///   in this push if that happened while the request was out, and at the
///   next session's start.
@MainActor
public final class PreferencesSyncCoordinator {
    private let client: CabalmailClient
    private let preferences: Preferences

    private var saveTask: Task<Void, Never>?
    /// The push in flight; whoever else asks for one waits on it.
    private var pushing: Task<Bool, Never>?
    /// The changes the server last refused, for this session only: no
    /// trigger sends them again until one of them changes.
    private var refused: [String: String]?
    /// When the server last took a flag list from this device
    /// (`sendUnsentForFeedQueue`).
    private var flagListTakenAt: ContinuousClock.Instant?
    /// Follows the connection while the session runs (`observeConnection`).
    private var connectionTask: Task<Void, Never>?
    /// What `observeConnection` follows: a test's stream, or nil for the
    /// client's own reachability.
    private let connection: AsyncStream<Bool>?
    /// Debounce window for pushes: a quick flurry of toggles collapses to one
    /// write. Matches `NavStateCoordinator`'s cursor-save cadence.
    private let saveDebounce: Duration
    /// Set by `stop()`. `start()`/`reconcile()` run their server pull as a
    /// detached task the caller doesn't hold, so sign-out can land while a
    /// fetch is in flight; without this guard the late response would apply
    /// the *previous* account's settings into whatever scope `Preferences`
    /// has activated by then — the cross-account leak, resurrected. A push
    /// that outlives the session must not settle the unsent keys either:
    /// by then they are the next account's.
    private var stopped = false

    /// How many times in a row one push takes a newer row and sends again
    /// before it leaves the rest to the next trigger. More than one means
    /// another device wrote between this one's answer and its next request.
    private static let newerRowLimit = 3
    /// How long after the server took a flag list the feed queue is still
    /// told so (`sendUnsentForFeedQueue`).
    private static let flagListRecency: Duration = .seconds(60)

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

    /// Starts observing local edits and the connection, then pulls the
    /// server's copy and sends whatever this device still owes it. Safe to
    /// call once per wired session.
    func start() async {
        guard !stopped else { return }
        // Before the first request, not after it: an edit made while the
        // pull is out has to be scheduled like any other (#2441).
        preferences.onLocalChange = { [weak self] in
            self?.scheduleSave()
        }
        observeConnection()
        await sync()
    }

    /// Detaches the local-edit observer, cancels any pending push, and marks
    /// the coordinator dead so an in-flight server pull is discarded instead
    /// of applied. Called on sign-out before the coordinator is released.
    /// A change still unsent stays recorded on disk for this account's next
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

    /// On return to the foreground: pulls the server's copy so a change
    /// made elsewhere lands mid-session, then sends a change still unsent.
    public func reconcile() async {
        await sync()
    }

    /// The feed queue's question when the server has refused a flag add
    /// (`RssUnsentSettings`): sends a settings change still waiting, which
    /// may hold the very flag, and says whether it went.
    ///
    /// With nothing waiting it still answers "sent" for a minute after the
    /// server took a flag list from this device: the push may have landed
    /// between the refusal and this question, and then the flag is on the
    /// server though nothing is unsent (#2441). Answered so wrongly, the
    /// queue sends the add once more and takes the second refusal as final.
    func sendUnsentForFeedQueue() async -> RssUnsentSettings {
        guard !stopped else { return .nothingUnsent }
        guard preferences.hasUnsentChanges else {
            if let flagListTakenAt, ContinuousClock.now - flagListTakenAt < Self.flagListRecency {
                return .sent
            }
            return .nothingUnsent
        }
        return await pushUnsent() ? .sent : .stillUnsent
    }

    /// Sends the keys this device has changed and the server has not taken;
    /// joins a push already in flight. True once nothing is left unsent.
    @discardableResult
    func pushUnsent() async -> Bool {
        if let pushing { return await pushing.value }
        guard !stopped else { return false }
        guard preferences.hasUnsentChanges else { return true }
        // Main-actor work, like this method: the task clears itself before
        // anyone waiting on it resumes, so no caller joins a finished push.
        let task = Task {
            let settled = await self.sendUntilSettled()
            self.pushing = nil
            return settled
        }
        pushing = task
        return await task.value
    }

    // MARK: - Requests

    private func sync() async {
        await pull()
        await pushUnsent()
    }

    /// Fetches the account's row and takes it (`Preferences.take`). True
    /// when the server answered.
    @discardableResult
    private func pull() async -> Bool {
        guard !stopped else { return false }
        let row: SyncedSettingsRow
        do {
            row = try await client.fetchSyncedSettings()
        } catch {
            CabalmailLog.warn("PreferencesSync", "settings pull failed; it goes again later: "
                + error.localizedDescription)
            return false
        }
        // The fetch may have raced a sign-out; this account's values must
        // not land in the next account's (already re-activated) scope.
        guard !stopped else { return false }
        preferences.take(row)
        return true
    }

    /// One push: requests until nothing is unsent, or until one fails, is
    /// refused, or the session ends.
    private func sendUntilSettled() async -> Bool {
        var newerRows = 0
        while !stopped {
            guard let changes = await changesToSend() else { return !preferences.hasUnsentChanges }
            guard changes != refused else { return false }
            switch await send(changes) {
            case .taken:
                // Around again, for an edit made while the request was out.
                continue
            case .refused:
                // Around again: an edit made while the request was out has
                // changed what is unsent, and gets its own request.
                continue
            case .newerRow:
                newerRows += 1
                guard newerRows <= Self.newerRowLimit else { return false }
            case .failed:
                return false
            }
        }
        return false
    }

    /// The unsent keys to send now, or nil when there is nothing to send
    /// or the row could not be read first. Nothing is sent before this
    /// device has read the row. (Nor can it be, after a build that
    /// recorded only that something was unsent: the pull is what says
    /// which keys.)
    private func changesToSend() async -> [String: String]? {
        let changes = preferences.unsentChanges()
        if preferences.hasSettingsRow, !changes.isEmpty { return changes }
        guard preferences.hasUnsentChanges else { return nil }
        guard await pull(), preferences.hasSettingsRow else { return nil }
        let afterThePull = preferences.unsentChanges()
        return afterThePull.isEmpty ? nil : afterThePull
    }

    /// How one request of a push went.
    private enum Answer {
        /// The server took the changes.
        case taken
        /// The server refused them (a 400).
        case refused
        /// The row had moved on (a 409); it has been taken, and the
        /// changes go again on its version.
        case newerRow
        /// The request did not reach the server, the server failed, or
        /// the session ended first.
        case failed
    }

    private func send(_ changes: [String: String]) async -> Answer {
        let result: SyncedSettingsSaveResult
        do {
            result = try await client.saveSyncedSettings(
                changes, expectedVersion: preferences.settingsVersion
            )
        } catch CabalmailError.http(status: 400, let body) {
            refused = changes
            CabalmailLog.warn("PreferencesSync", "the server refused the settings; "
                + "they go again once they change: " + body)
            return .refused
        } catch {
            CabalmailLog.warn("PreferencesSync", "settings push failed; it goes again later: "
                + error.localizedDescription)
            return .failed
        }
        // After `stop()` the settings may already be the next account's.
        guard !stopped else { return .failed }
        switch result {
        case .saved(let version):
            if changes[SettingsSyncLedger.flagPaletteKey] != nil { flagListTakenAt = .now }
            preferences.settingsTaken(changes, version: version)
            return .taken
        case .stale(let row):
            preferences.take(row)
            return .newerRow
        }
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

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = nil
        // An edit that put a setting back to what the server holds leaves
        // nothing to send.
        guard preferences.hasUnsentChanges else { return }
        let debounce = saveDebounce
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.pushUnsent()
        }
    }
}
