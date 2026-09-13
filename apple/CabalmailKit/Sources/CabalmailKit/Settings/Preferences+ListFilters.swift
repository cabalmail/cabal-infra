import Foundation

/// The sticky filter pills that live in the synced preferences: one entry
/// per mail folder, and the single all-feeds pill. (A single feed's or feed
/// folder's pill lives on its own server row instead — `RssSubscription`
/// and `RssFolder`'s `defaultFilter`.)
extension Preferences {
    /// The wire-key prefix of a mail folder's pill in the `app` map:
    /// `filter:mail:<folder path>` → `all` | `unread` | `flagged` (the
    /// all-feeds pill is `filter:feeds:all` in the same family). One key
    /// per folder rather than one JSON map under a single key (the
    /// `flag_palette` shape) so the server's per-key merge applies: two
    /// devices changing two folders' pills never clobber each other, and a
    /// stale device can only overwrite the folders it knows.
    public static let mailFilterWirePrefix = "filter:mail:"

    /// The pill `path`'s list opens on; All for a folder never changed.
    public func mailFolderFilter(for path: String) -> MessageFilter {
        mailFolderFilters[path] ?? .defaultForFolders
    }

    /// Makes `filter` the pill `path`'s list opens on. A choice of the
    /// default is stored (not removed) so it syncs over another device's
    /// earlier choice.
    public func setMailFolderFilter(_ filter: MessageFilter, for path: String) {
        guard !path.isEmpty, mailFolderFilters[path] != filter else { return }
        mailFolderFilters[path] = filter
    }

    /// The `app`-map entries the payload carries for the mail folders: one
    /// `filter:mail:<path>` key per folder whose pill has been set.
    func folderFilterWireEntries() -> [String: String] {
        mailFolderFilters.reduce(into: [:]) { entries, entry in
            entries[Self.mailFilterWirePrefix + entry.key] = entry.value.rawValue
        }
    }

    /// `applyRemote`'s arm for the mail folders: the fetched map's entries
    /// merged over the local ones, written only when something changed.
    func applyRemoteFolderFilters(_ remote: [String: String]) {
        let merged = Self.mergeRemoteFolderFilters(remote, over: mailFolderFilters)
        if merged != mailFolderFilters { mailFolderFilters = merged }
    }

    /// The local store form of `mailFolderFilters`: a JSON object of folder
    /// path to pill, keys sorted so equal maps store identically.
    static func encodeFolderFilters(_ filters: [String: MessageFilter]) -> String {
        let raw = filters.mapValues(\.rawValue)
        guard let data = try? JSONSerialization.data(withJSONObject: raw,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Inverse of `encodeFolderFilters`. An entry whose pill this build does
    /// not know is dropped; an unparseable value reads as no entries.
    static func decodeFolderFilters(_ text: String?) -> [String: MessageFilter] {
        guard let text, let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return raw.reduce(into: [:]) { result, entry in
            if let filter = MessageFilter(rawValue: entry.value) { result[entry.key] = filter }
        }
    }

    /// The `filter:mail:<path>` entries of a fetched `app` map, merged over
    /// `current` (the server wins per folder; folders it has no entry for
    /// keep their local pill).
    static func mergeRemoteFolderFilters(
        _ remote: [String: String], over current: [String: MessageFilter]
    ) -> [String: MessageFilter] {
        var merged = current
        for (key, raw) in remote where key.hasPrefix(mailFilterWirePrefix) {
            let path = String(key.dropFirst(mailFilterWirePrefix.count))
            guard !path.isEmpty, let filter = MessageFilter(rawValue: raw) else { continue }
            merged[path] = filter
        }
        return merged
    }
}
