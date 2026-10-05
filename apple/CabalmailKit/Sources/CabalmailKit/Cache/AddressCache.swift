import Foundation

/// Cache for the user's address list.
///
/// Mirrors the React app's `localStorage[ADDRESS_LIST]` pattern
/// (`react/admin/src/ApiClient.js`): the list is fetched once per session
/// and invalidated on any mutation (`newAddress` / `revokeAddress`).
///
/// Given a directory, every list the server returns is also written to disk,
/// so a launch without a connection still knows which addresses the account
/// can send from. `lastKnown()` reads that copy back; it never answers `get()`,
/// so a session that started offline still fetches once the server is
/// reachable. Without a directory (tests, previews) the cache is memory-only.
public actor AddressCache {
    private var addresses: [Address]?
    private let fileURL: URL?

    /// Bumped by every invalidation. A fetch reads it before going to the
    /// server and stores its answer only if it hasn't moved, so a list read
    /// before a revoke can't put the revoked address back afterwards.
    public private(set) var generation = 0

    public init(directory: URL? = nil) {
        self.fileURL = directory?.appendingPathComponent("addresses.json")
    }

    public func get() -> [Address]? { addresses }

    public func set(_ addresses: [Address]) {
        self.addresses = addresses
        save(addresses)
    }

    /// `set(_:)`, unless the cache has been invalidated since `generation`
    /// was read.
    public func set(_ addresses: [Address], ifUnchangedSince generation: Int) {
        guard generation == self.generation else { return }
        set(addresses)
    }

    /// The list last written to disk, possibly by an earlier launch. Nil when
    /// nothing has been saved since the last `clear()`, or when the cache is
    /// memory-only.
    public func lastKnown() -> [Address]? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([Address].self, from: data)
    }

    /// Drops the in-memory list so the next read refetches. The saved copy
    /// stays: after a new address, a favorite, or a suspension every address
    /// in it can still send, and it is what an offline launch falls back on
    /// until the next fetch replaces it.
    public func invalidate() {
        addresses = nil
        generation += 1
    }

    /// `invalidate()`, and also takes `address` out of the saved copy, so a
    /// revoked address can't come back as an offline From choice.
    public func invalidate(removing address: String) {
        invalidate()
        guard var saved = lastKnown() else { return }
        saved.removeAll { $0.address == address }
        save(saved)
    }

    /// Forgets the list in memory and on disk. Sign-out calls this so the
    /// next account on the device doesn't inherit this one's addresses.
    public func clear() {
        invalidate()
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func save(_ addresses: [Address]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(addresses).write(to: fileURL, options: .atomic)
        } catch {
            CabalmailLog.warn("AddressCache", "couldn't save the address list: \(error)")
        }
    }
}
