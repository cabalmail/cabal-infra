import Foundation

/// Main windows by their identity (`commandWindowID`), each mapped to an
/// object the registry does not keep alive: a window's navigator for the
/// deep-link router, a window's scene session for scene activation on iPad.
///
/// A window gone without saying so drops out when its object goes. An
/// object registered under a new identity leaves its old one: iPadOS can
/// reconnect a scene under a fresh window identity while its session lives
/// on.
@MainActor
struct WindowRegistry<Value: AnyObject> {
    private struct Entry {
        let window: UUID
        weak var value: Value?
    }

    /// Oldest registration first.
    private var entries: [Entry] = []

    /// Registers `value` as `window`'s, replacing what `window` had and any
    /// other window `value` was registered under.
    mutating func register(_ value: Value, for window: UUID) {
        entries.removeAll { $0.window == window || $0.value == nil || $0.value === value }
        entries.append(Entry(window: window, value: value))
    }

    /// Forgets `window`, but only while it still holds `value` when one is
    /// given: a torn-down instance cannot remove its replacement.
    mutating func remove(_ window: UUID, holding value: Value? = nil) {
        entries.removeAll { entry in
            entry.window == window && (value.map { entry.value === $0 } ?? true)
        }
    }

    /// The object `window` registered, if it is still alive.
    func value(for window: UUID?) -> Value? {
        guard let window else { return nil }
        return entries.last { $0.window == window }?.value
    }

    /// The window `value` is registered under.
    func window(holding value: Value?) -> UUID? {
        guard let value else { return nil }
        return entries.last { $0.value === value }?.window
    }

    /// The most recently registered object still alive.
    var latest: Value? {
        entries.last { $0.value != nil }?.value
    }
}
