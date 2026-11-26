import Foundation

extension AccountDirectory {
    /// What a launch does to the cache root before the first client is
    /// built (`docs/1.x/post-wave-3/sqlite-mail-store.md`, PR 1.2).
    /// `remembered` is the account the install last signed in as, signed in
    /// still or not; nil when it remembers none.
    ///
    /// 1. Every directory in `accounts/` but the remembered account's is
    ///    removed: another account's, which a session that ended without
    ///    its wipe left behind, and whatever a sign-out's removal that
    ///    failed left under a being-deleted name. The remembered account's
    ///    own directory stays, also when its session turns out to have
    ///    expired: signing in again as that account finds its mail saved.
    /// 2. The message lists, bodies and folder state a build from before
    ///    the account directory kept in the root are moved into the
    ///    remembered account's directory, replacing what is there. They are
    ///    that account's: every wipe since has removed them otherwise. They
    ///    replace rather than yield because the older build ran more
    ///    recently than the newer one that made the directory. With no
    ///    remembered account they are deleted.
    ///
    /// Running it again changes nothing. It is not for a root a client
    /// without an account keeps its caches in (`CabalmailClient.make`), and
    /// it must finish before a client of the remembered account opens its
    /// stores.
    public static func prepareAtLaunch(root: URL, remembered: AccountIdentity?) async {
        await AccountStoreRegistry.shared.removeAccountDirectories(in: root, except: remembered)
        adoptLegacyCaches(in: root, for: remembered, using: .default)
    }

    /// Step 2 of `prepareAtLaunch(root:remembered:)`. A rename each, on one
    /// volume. One that fails leaves that cache in the root, where the next
    /// launch tries again and a wipe removes it.
    static func adoptLegacyCaches(in root: URL, for owner: AccountIdentity?, using fileManager: FileManager) {
        for legacy in legacyCacheDirectories(in: root) where fileManager.fileExists(atPath: legacy.path) {
            let name = legacy.lastPathComponent
            guard let owner else {
                if let error = WipeReport.remove(legacy, using: fileManager) {
                    WipeReport.failed("mail saved by an earlier version (\(name))", error)
                }
                continue
            }
            let home = url(for: owner, in: root)
            let destination = home.appendingPathComponent(name, isDirectory: true)
            do {
                try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
                if let error = WipeReport.remove(destination, using: fileManager) { throw error }
                try fileManager.moveItem(at: legacy, to: destination)
            } catch {
                CabalmailLog.warn(
                    "AccountDirectory",
                    "mail saved by an earlier version (\(name)) was not moved to its account: \(error)"
                )
            }
        }
    }
}
