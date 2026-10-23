import Foundation

/// Which nodes of a sidebar tree *this window* has collapsed.
///
/// The two trees persist their collapsed set (`SidebarTreeExpansion`), and
/// that set used to be one device-wide `@AppStorage` value every window
/// rendered: Collapse All in one Mac window collapsed the tree in all of
/// them, so #1999's "act on the window in front only" could not be seen
/// however well the command routed (#2039). A window now keeps its own set
/// in scene storage, tagged with the account the way `StoredRoute` is, and
/// a window that has none seeds from the device-wide value — so a new window
/// opens the tree the way the last change anywhere left it and then goes its
/// own way. Every change writes both, which is what keeps that seed current.
///
/// The device-wide encoding is unchanged (sorted, newline-joined; folder
/// paths and feed folder ids hold no newline), so a value stored before this
/// is read back as it always was.
///
/// `account-isolation.md`'s C1 clears the device-wide keys when a different
/// account signs in and cannot reach scene storage, which is why the account
/// travels with the window's own set: another account's is ignored, not read.
struct SidebarCollapse: Codable, Equatable {
    var account: StoredRoute.Account
    /// Sorted, so the stored string is stable for a given set.
    var collapsed: [String]

    /// The set this window shows: its own when scene storage holds one for
    /// `account`, else the device-wide set it seeds from. A window's own set
    /// is skipped when nothing is stored, when it does not decode, and when
    /// it belongs to another account.
    static func effective(
        scene: String,
        device: String,
        for account: StoredRoute.Account
    ) -> Set<String> {
        if let own = stored(in: scene, for: account) { return own }
        return decodeDevice(device)
    }

    /// What `scene` holds for `account`, or nil in the three seed-from-device
    /// cases above.
    static func stored(in scene: String, for account: StoredRoute.Account) -> Set<String>? {
        guard !scene.isEmpty,
              let data = scene.data(using: .utf8),
              let stored = try? JSONDecoder().decode(SidebarCollapse.self, from: data),
              stored.account == account
        else { return nil }
        return Set(stored.collapsed)
    }

    /// What a window writes into its own scene storage when it first mounts:
    /// the device-wide set it seeds from. Nil when the window already has a
    /// set of its own for this account.
    ///
    /// The seed has to be taken **once per window**, not left as a running
    /// default: `effective` falls back to the device-wide value, and that
    /// value moves every time any window changes its tree, so a window that
    /// had never touched its own would follow the others' changes for its
    /// whole life — measured live on 2026-10-23, two Mac windows, both back
    /// to 4 feed rows. Writing the seed is what makes a window's set its own.
    ///
    /// A window holding another account's set seeds afresh, so it renders
    /// the device-wide value until this runs rather than that account's.
    static func seed(scene: String, device: String, for account: StoredRoute.Account) -> String? {
        guard stored(in: scene, for: account) == nil else { return nil }
        return self.scene(decodeDevice(device), for: account)
    }

    /// `set` encoded for this window's scene storage, tagged with `account`.
    static func scene(_ set: Set<String>, for account: StoredRoute.Account) -> String {
        let payload = SidebarCollapse(account: account, collapsed: set.sorted())
        guard let data = try? JSONEncoder().encode(payload),
              let encoded = String(bytes: data, encoding: .utf8)
        else { return "" }
        return encoded
    }

    /// `set` in the device-wide encoding the key has always used.
    static func device(_ set: Set<String>) -> String {
        set.sorted().joined(separator: "\n")
    }

    /// The set a device-wide value holds.
    static func decodeDevice(_ device: String) -> Set<String> {
        guard !device.isEmpty else { return [] }
        return Set(device.split(separator: "\n").map(String.init))
    }
}
