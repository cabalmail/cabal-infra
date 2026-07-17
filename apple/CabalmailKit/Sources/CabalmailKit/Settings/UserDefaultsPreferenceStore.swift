import Foundation

/// Production `PreferenceStore` — plain `UserDefaults`, deliberately
/// local to this device.
///
/// Cross-device settings sync rides the Cabalmail account through
/// `/get_preferences` / `/set_preferences` (the app's
/// `PreferencesSyncCoordinator`); this store only keeps each account's
/// last-known values for fast, offline reads. An earlier design also
/// mirrored every value into `NSUbiquitousKeyValueStore`, but that syncs
/// on the Apple ID — the wrong identity for account-scoped settings, and
/// one iCloud store shared by every Cabalmail account on the Apple ID —
/// and the apps never carried the kvstore entitlement, so it never
/// synced in practice anyway. Nothing reads or writes iCloud now, not
/// even as a fallback.
@MainActor
public final class UserDefaultsPreferenceStore: PreferenceStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func stringValue(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// No-ops: `UserDefaults` has no cross-device push to observe —
    /// server-driven updates arrive through `Preferences.applyRemote(_:)`
    /// instead. The hooks stay on the protocol for
    /// `InMemoryPreferenceStore`, whose tests drive the external-change
    /// path through them.
    public func startObserving(_ handler: @escaping @MainActor () -> Void) {}
    public func stopObserving() {}
}
