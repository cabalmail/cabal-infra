import Foundation

// What `Preferences` owes the server and what it takes from it. The
// bookkeeping itself is `SettingsSyncLedger`; this file keeps one per
// account in the store and applies what it decides. The session's
// `PreferencesSyncCoordinator` makes the requests.

extension Preferences {
    /// True while this account's settings hold a change the server has not
    /// taken: from a user's edit until a push of it is accepted, across
    /// relaunches. Never a reason to fire `onLocalChange`, and false while
    /// no account is active.
    public var hasUnsentChanges: Bool {
        ledger.hasUnsent || hasLegacyUnsentMark
    }

    /// Whether this device has read the account's row. Until it has,
    /// nothing is sent: its values are not yet the account's (#2452).
    public var hasSettingsRow: Bool { ledger.hasRow }

    /// The row's version as last answered: what a push says it was built
    /// on. Nil before the row is read, and with a server that predates it.
    public var settingsVersion: Int? { ledger.version }

    /// The settings to send: the keys changed on this device that the
    /// server has not taken, at their values now. Never the whole map.
    public func unsentChanges() -> [String: String] {
        ledger.changes(in: appPreferencesPayload())
    }

    /// The server took `sent`, and answered `version`. A key changed again
    /// since it was sent stays unsent.
    public func settingsTaken(_ sent: [String: String], version: Int?) {
        guard accountScope != nil else { return }
        ledger.took(sent, version: version, values: appPreferencesPayload())
        saveLedger()
    }

    /// Takes the account's row as the server answered it, from a pull or
    /// with a refused push: its value for every key this device does not
    /// owe, and the flag list merged with this device's when it does. The
    /// device's own unsent changes stay as they are, so a pull never has
    /// to wait for a push. False, with nothing applied, for a row older
    /// than the one already held (an answer overtaken on its way).
    @discardableResult
    public func take(_ row: SyncedSettingsRow) -> Bool {
        guard accountScope != nil, !ledger.isOlder(row) else { return false }
        // A build up to 1.53.0 marked "something is unsent" and no more.
        // Whatever this device holds that differs from the row is what it
        // would have sent, so that is what it owes, this once.
        let legacy = hasLegacyUnsentMark
        let apply = ledger.rebase(
            onto: row,
            values: appPreferencesPayload(),
            stored: storedSyncedKeys(),
            owingDifferences: legacy
        )
        if legacy { storeString(nil, for: .unsentChanges) }
        saveLedger()
        applyRemote(apply)
        return true
    }

    // MARK: - Called by Preferences itself

    /// After a user's edit has been stored: owes the server the keys whose
    /// values it changed.
    func noteUserEdit() {
        guard accountScope != nil else { return }
        let now = syncedValues(gated: false)
        let changed = Set(now.filter { editSnapshot[$0.key] != $0.value }.keys)
        editSnapshot = now
        guard !changed.isEmpty else { return }
        ledger.edited(changed, values: now)
        saveLedger()
    }

    /// After a reload: the active account's ledger, and its values as the
    /// ones the next edit is compared with.
    func loadSyncState() {
        ledger = storedString(.syncLedger)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SettingsSyncLedger.self, from: $0) }
            ?? SettingsSyncLedger()
        editSnapshot = syncedValues(gated: false)
    }

    private var hasLegacyUnsentMark: Bool {
        storedString(.unsentChanges) == "1"
    }

    private func saveLedger() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = (try? encoder.encode(ledger)).flatMap { String(data: $0, encoding: .utf8) }
        storeString(text, for: .syncLedger)
    }
}
