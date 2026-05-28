import Foundation

#if canImport(Foundation) && !os(Linux)
/// Production `PreferenceStore` — writes go to both `UserDefaults` (fast
/// local reads) and `NSUbiquitousKeyValueStore` (cross-device sync).
///
/// iCloud pushes arrive on the main queue via
/// `NSUbiquitousKeyValueStore.didChangeExternallyNotification`; the store
/// forwards them to the `startObserving` handler, which drives
/// `Preferences.reload()` above.
///
/// The store still functions without an iCloud account — `NSUbiquitousKey
/// ValueStore` simply becomes a no-op, and `UserDefaults` carries the
/// whole load. On-device-only installs (privacy-conscious users who have
/// disabled iCloud) therefore degrade gracefully.
@MainActor
public final class UbiquitousPreferenceStore: PreferenceStore {
    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore
    private var observer: NSObjectProtocol?
    private var handler: (@MainActor () -> Void)?

    public init(
        defaults: UserDefaults = .standard,
        cloud: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloud = cloud
        // Trigger an initial pull from the cloud store so first-launch-on-
        // a-second-device doesn't show defaults until a change arrives.
        cloud.synchronize()
    }

    public func stringValue(forKey key: String) -> String? {
        // Prefer the local value — it's either the most recent write from
        // this device or a cloud value we already mirrored here. Fall back
        // to the cloud store when a device is brand new and iCloud hasn't
        // yet fired the external-change notification.
        if let local = defaults.string(forKey: key) { return local }
        return cloud.string(forKey: key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
            cloud.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
            cloud.removeObject(forKey: key)
        }
        cloud.synchronize()
    }

    public func startObserving(_ handler: @escaping @MainActor () -> Void) {
        stopObserving()
        self.handler = handler
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] notification in
            // Extract the Sendable payload on whichever queue Foundation
            // chose (main, per the registration), then hop explicitly to
            // the main actor for the stored-property writes. The `@MainActor`
            // annotation on this class makes `self` Sendable, which is what
            // lets the weak capture survive the `@Sendable` closure
            // signature the strict-concurrency `addObserver` requires.
            let changedKeys = (notification.userInfo?[
                NSUbiquitousKeyValueStoreChangedKeysKey
            ] as? [String]) ?? []
            MainActor.assumeIsolated {
                self?.applyExternalChanges(keys: changedKeys)
            }
        }
    }

    private func applyExternalChanges(keys: [String]) {
        for key in keys {
            if let value = cloud.string(forKey: key) {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        handler?()
    }

    public func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
#endif
