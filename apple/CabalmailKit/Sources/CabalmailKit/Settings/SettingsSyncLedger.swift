import Foundation

/// The account's settings row as the server answers it: the `app` map and
/// the count of writes the row has had (`docs/settings-sync.md`).
public struct SyncedSettingsRow: Equatable, Sendable {
    /// The `app` map, wire key to value.
    public var app: [String: String]
    /// The row's version, or nil from a server that predates it.
    public var version: Int?

    public init(app: [String: String], version: Int?) {
        self.app = app
        self.version = version
    }
}

/// How a settings write was answered.
public enum SyncedSettingsSaveResult: Equatable, Sendable {
    /// Written. `version` is the row's new version, or nil from a server
    /// that predates it.
    case saved(version: Int?)
    /// Not written: the row had moved on from the version the write named.
    /// The row as it is now, to merge into and send again on.
    case stale(SyncedSettingsRow)
}

/// What this device knows of an account's settings row and what it owes
/// it: the row as last seen, and the keys changed here that the server has
/// not taken. `Preferences` keeps one per account, on disk beside the
/// values, so a change the app could not send survives a relaunch.
///
/// It exists so that a device sends only what was changed on it. A push
/// used to carry every key at this device's values, so a device that had
/// not seen another device's change, or had never read the row at all,
/// put its own copy over the account's (#2452, #2464). With the keys
/// known, a push carries those alone, and a pull applies to every other
/// key, so it never has to wait for a push.
///
/// Pure bookkeeping: it reads and writes nothing itself.
public struct SettingsSyncLedger: Codable, Equatable, Sendable {
    /// The flag list's wire key: the one value that is merged, not taken
    /// whole, when both sides changed it.
    public static let flagPaletteKey = "flag_palette"

    /// True once this device has read the account's row (a pull, or the
    /// row a refused push was answered with). Until then nothing is sent.
    public private(set) var hasRow = false
    /// The row's version as last answered: what the next push says it was
    /// built on. Nil until the row is read, and with a server that
    /// predates the version.
    public private(set) var version: Int?
    /// The `app` map as the server last answered or took it.
    public private(set) var base: [String: String] = [:]
    /// The wire keys changed on this device that the server has not taken.
    public private(set) var unsent: Set<String> = []

    public init() {}

    /// Whether anything is owed to the server.
    public var hasUnsent: Bool { !unsent.isEmpty }

    // MARK: - Local edits

    /// Records a user's edit of `keys`. `values` is the settings after it.
    /// A key put back to what the server holds is no longer owed.
    public mutating func edited(_ keys: Set<String>, values: [String: String]) {
        unsent.formUnion(keys)
        guard hasRow else { return }
        unsent = unsent.filter { key in
            guard let mine = values[key], let theirs = base[key] else { return true }
            return !Self.same(key, mine, theirs)
        }
    }

    /// The part of `values` to send: the unsent keys at their values now.
    public func changes(in values: [String: String]) -> [String: String] {
        values.filter { unsent.contains($0.key) }
    }

    // MARK: - The server's answers

    /// The server took `sent`. A key changed again while the request was
    /// out (`values` is the settings now) stays owed.
    public mutating func took(_ sent: [String: String], version: Int?, values: [String: String]) {
        base.merge(sent) { _, new in new }
        self.version = version
        unsent = unsent.filter { key in
            guard let was = sent[key] else { return true }
            return values[key] != was
        }
    }

    /// Whether `row` is older than the row this device already holds: an
    /// answer that was overtaken on its way, which must not be applied.
    public func isOlder(_ row: SyncedSettingsRow) -> Bool {
        guard let version, let theirs = row.version else { return false }
        return theirs < version
    }

    /// Takes the row as the server answered it, from a pull or with a
    /// refused push, and returns the values to write into the settings:
    /// the row's value for every key not owed, and for the flag list when
    /// it is owed, the two lists merged (`FlagPalette.merged`).
    ///
    /// - `values`: the settings as they are now.
    /// - `stored`: the keys this device holds a stored value for, set here
    ///   or pulled earlier. One of them the row lacks is a value only this
    ///   device holds, and becomes owed.
    /// - `owingDifferences`: also owe every stored key whose value differs
    ///   from the row's. For a build's first sync after one that marked
    ///   "something is unsent" without saying what.
    public mutating func rebase(
        onto row: SyncedSettingsRow,
        values: [String: String],
        stored: Set<String>,
        owingDifferences: Bool = false
    ) -> [String: String] {
        for key in stored {
            guard let mine = values[key] else { continue }
            guard let theirs = row.app[key] else {
                unsent.insert(key)
                continue
            }
            if owingDifferences, !Self.same(key, mine, theirs) { unsent.insert(key) }
        }
        var apply: [String: String] = [:]
        var after = values
        for (key, theirs) in row.app {
            if !unsent.contains(key) {
                apply[key] = theirs
                after[key] = theirs
            } else if key == Self.flagPaletteKey, let merged = mergedPalette(mine: values[key], theirs: theirs) {
                apply[key] = merged
                after[key] = merged
            }
        }
        unsent = unsent.filter { key in
            guard let mine = after[key] else { return false }
            guard let theirs = row.app[key] else { return true }
            return !Self.same(key, mine, theirs)
        }
        base = row.app
        version = row.version
        hasRow = true
        return apply
    }

    /// The owed flag list merged with the row's, as its wire string, or
    /// nil when either does not parse (the owed list then stays as it is).
    private func mergedPalette(mine: String?, theirs: String) -> String? {
        guard let mine = mine.flatMap(FlagPalette.decode),
              let theirs = FlagPalette.decode(theirs)
        else { return nil }
        let base = base[Self.flagPaletteKey].flatMap(FlagPalette.decode) ?? []
        return FlagPalette.encode(FlagPalette.merged(base: base, mine: mine, theirs: theirs))
    }

    /// Whether two wire values of `key` say the same thing. The flag list
    /// is compared as a list: the server stores it in its own spelling.
    static func same(_ key: String, _ one: String, _ other: String) -> Bool {
        if one == other { return true }
        guard key == flagPaletteKey,
              let one = FlagPalette.decode(one), let other = FlagPalette.decode(other)
        else { return false }
        return one == other
    }
}

// MARK: - Merging two edits of the flag list

extension FlagPalette {
    /// One flag list from two that both started as `base`: this device's
    /// (`mine`) and the server's (`theirs`). The list is one value on the
    /// wire, so without this the later write would undo the earlier one,
    /// and a flag another device had just added would read to the server
    /// as deleted.
    ///
    /// Per flag: one this device changed, added or deleted is as this
    /// device has it, and every other is as the server has it. Where both
    /// changed the same flag, this device's wins, as its whole list did
    /// before. The order is this device's when it reordered the flags it
    /// shares with `base`, and otherwise the server's; flags the chosen
    /// order does not hold follow it, in the other list's order.
    ///
    /// Two flags added on the two sides are two flags, though both apps
    /// give a new flag the first free slot and so the same one
    /// (`firstFreeSlot(in:)`). The server's keeps the slot, which may
    /// already be on messages, and this device's moves to the next slot
    /// neither list uses. With no slot left, this device's takes the slot,
    /// as a changed flag does.
    public static func merged(
        base: [FlagPaletteEntry], mine: [FlagPaletteEntry], theirs: [FlagPaletteEntry]
    ) -> [FlagPaletteEntry] {
        let bySlot: ([FlagPaletteEntry]) -> [String: FlagPaletteEntry] = { entries in
            Dictionary(entries.map { ($0.slot, $0) }) { first, _ in first }
        }
        let (was, there) = (bySlot(base), bySlot(theirs))
        let mine = movingNewFlags(in: mine, offSlotsNewIn: there, since: was)
        let here = bySlot(mine)
        var kept: [String: FlagPaletteEntry] = [:]
        for slot in Set(here.keys).union(there.keys) {
            kept[slot] = here[slot] != was[slot] ? here[slot] : there[slot]
        }
        let shared = Set(was.keys).intersection(here.keys)
        let reordered = mine.map(\.slot).filter(shared.contains) != base.map(\.slot).filter(shared.contains)
        let (lead, rest) = reordered ? (mine, theirs) : (theirs, mine)
        var order = lead.map(\.slot)
        order += rest.map(\.slot).filter { !order.contains($0) }
        var seen: Set<String> = []
        return order.compactMap { slot in
            seen.insert(slot).inserted ? kept[slot] : nil
        }
    }

    /// `mine` with each flag it added on a keyword slot where the server's
    /// list (`there`) added a different one moved to a slot neither list
    /// uses, for as long as there is one.
    private static func movingNewFlags(
        in mine: [FlagPaletteEntry],
        offSlotsNewIn there: [String: FlagPaletteEntry],
        since was: [String: FlagPaletteEntry]
    ) -> [FlagPaletteEntry] {
        var used = Set(mine.map(\.slot)).union(there.keys)
        return mine.map { entry in
            guard was[entry.slot] == nil, let other = there[entry.slot], other != entry,
                  let free = slots.first(where: { !used.contains($0) }), slots.contains(entry.slot)
            else { return entry }
            used.insert(free)
            return FlagPaletteEntry(slot: free, label: entry.label, color: entry.color)
        }
    }
}
