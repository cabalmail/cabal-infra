import Foundation
import CabalmailKit

/// Keeps `AppState`'s per-folder counts in step with the saved folder state
/// (`FolderStateCache`) that an offline launch draws from.
///
/// Two jobs. It writes every count the session learns or changes (a live
/// STATUS, a message read, Mark All as Read, Empty Trash) through to the
/// saved state, so an offline launch shows what the app last showed rather
/// than the STATUS before those changes. And it remembers which counts were
/// seeded from saved state while offline (`FolderListViewModel`), so the
/// folder list can drop them once a live list arrives: a recount cut short
/// then leaves those badges blank, as online, rather than old numbers shown
/// as current.
@MainActor
final class SavedFolderCounts {
    /// The session client's `folderStateCache`; nil when signed out. Set by
    /// `AppState.wireSession`, or by a test.
    var cache: FolderStateCache?

    /// Folders whose counts in `AppState` came from saved state and haven't
    /// been replaced by a count the session knows for itself.
    private(set) var seededPaths: Set<String> = []

    /// The last write, so writes land in the order the changes were made.
    private var lastWrite: Task<Void, Never>?

    /// A count seeded from saved state.
    func markSeeded(_ folderPath: String) {
        seededPaths.insert(folderPath)
    }

    /// Hands over and forgets the seeded paths, for the folder list to clear.
    func takeSeeded() -> Set<String> {
        defer { seededPaths.removeAll() }
        return seededPaths
    }

    /// A folder's counts are known: set in `AppState` from a live STATUS or a
    /// change with a known result (Mark All as Read, Empty Trash), or shown by
    /// a message list that withheld a STATUS reply as older than its own
    /// counts. Saves them for the next offline launch; the folder is no
    /// longer seeded.
    func countChanged(_ folderPath: String, unread: Int, total: Int?) {
        seededPaths.remove(folderPath)
        save(folderPath, unread: unread, total: total)
    }

    /// A delta is being applied to a folder's unread count (a message read,
    /// moved or deleted), from `known`, the count before it. Saves the result
    /// when there was a count to apply it to: from an unknown base, `AppState`
    /// guesses 0, and that guess must not replace a real saved count. A
    /// seeded count stays seeded, since the result is still derived from it.
    func unreadAdjusted(_ folderPath: String, from known: Int?, by delta: Int) {
        guard let known else { return }
        save(folderPath, unread: max(0, known + delta), total: nil)
    }

    private func save(_ folderPath: String, unread: Int, total: Int?) {
        guard let cache else { return }
        let previous = lastWrite
        lastWrite = Task {
            await previous?.value
            await cache.recordLocalCounts(unseen: unread, messages: total, for: folderPath)
        }
    }

    /// Sign-out: nothing more is written, and nothing is seeded.
    func reset() {
        cache = nil
        seededPaths.removeAll()
        lastWrite = nil
    }
}
