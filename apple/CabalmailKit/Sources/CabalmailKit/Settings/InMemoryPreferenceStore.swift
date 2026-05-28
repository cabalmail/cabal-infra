import Foundation

/// Storage adapter that keeps values in a dictionary. Useful for SwiftUI
/// previews and unit tests — `simulateExternalChange(_:)` mimics the iCloud
/// push notification path that real deployments exercise.
@MainActor
public final class InMemoryPreferenceStore: PreferenceStore {
    private var values: [String: String] = [:]
    private var handler: (@MainActor () -> Void)?

    public init(initialValues: [String: String] = [:]) {
        self.values = initialValues
    }

    public func stringValue(forKey key: String) -> String? {
        values[key]
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    public func startObserving(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    public func stopObserving() {
        handler = nil
    }

    /// Applies a mutation to the backing dictionary and then fires the
    /// external-change handler, as if another device pushed the change
    /// through iCloud's key-value store.
    public func simulateExternalChange(_ mutation: (InMemoryPreferenceStore) -> Void) {
        mutation(self)
        handler?()
    }

    /// Mutates the dictionary without firing the observer, mirroring a
    /// `UbiquitousPreferenceStore` write that originated locally.
    public func setSilently(_ value: String?, forKey key: String) {
        setString(value, forKey: key)
    }
}
