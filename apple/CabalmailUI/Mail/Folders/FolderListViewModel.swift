import Foundation
import Observation
import CabalmailKit

/// Backs `FolderListView`. Owns the folder list + unread counts, re-fetches
/// on explicit refresh.
///
/// Folder ordering follows the plan's sidebar layout: Inbox pinned first,
/// then user folders, then system folders grouped (Sent/Drafts/Trash/Junk).
///
/// Subscription is the user's signal about *attention*: subscribed folders
/// get their counts refreshed proactively (INBOX first so the user lands
/// in the inbox ASAP, then the rest concurrently), while unsubscribed
/// folders are strictly on-demand — `refreshFolderCount(path:)` is the
/// only path that ever touches them, and only when the user selects one.
@Observable
@MainActor
final class FolderListViewModel {
    var folders: [Folder] = []
    var isLoading = false
    var errorMessage: String?
    /// True while `folders` is the list an earlier launch saved, drawn because
    /// the server can't be reached. It can lag the server, so the parent's
    /// launch landing doesn't reconcile against it.
    private(set) var isShowingSavedCopy = false
    /// A load reached an outcome: the server's list, the saved copy drawn
    /// because the server couldn't be reached, or an error worth showing. A
    /// load cut short by its own task's cancellation (the sidebar leaving the
    /// screen mid-load, as on iPhone when the launch pushes INBOX over it)
    /// leaves this false, so the next appearance loads again
    /// (`reloadIfCutShort`, #1908): `RulesViewModel.load`'s rule (#1328).
    private(set) var hasAttemptedLoad = false
    /// Paths whose counts are currently being fetched on-demand (lazy
    /// unsubscribed selection or the in-pane refresh button). The view
    /// reads this to render a spinner on the unsubscribed-folder banner's
    /// Refresh button.
    var refreshingPaths: Set<String> = []

    private let client: CabalmailClient
    /// The session's shared mail state: the sidebar's counts and subscribed
    /// folders, which this model publishes.
    private let mailStore: MailSessionStore
    /// Cap concurrent STATUS walks during the subscribed back-fill. The
    /// Lambda is happy to be hit in parallel, but the shared IMAP
    /// connection underneath serializes anyway — keeping this small
    /// avoids stacking dozens of pending tasks on first launch without
    /// changing real throughput.
    private let subscribedRefreshConcurrency = 4

    init(client: CabalmailClient, mailStore: MailSessionStore) {
        self.client = client
        self.mailStore = mailStore
    }

    /// Manual refresh path (toolbar / pull-to-refresh on the sidebar).
    /// Re-fetches the folder list, then re-fetches subscribed-folder
    /// counts only. Previously-cached unsubscribed counts (from a user
    /// selection earlier in the session) survive the refresh per the
    /// subscription contract: we only spend resources proactively on
    /// folders the user has explicitly subscribed to.
    func refresh() async {
        await loadFolderList()
        await refreshInboxCount()
        await refreshSubscribedCounts()
    }

    /// The sidebar's `.task` on each appearance after the one that built this
    /// model: a first load cut short (#1908) is loaded again, as a manual
    /// refresh would. Once any load has reached an outcome this is a no-op,
    /// so pushing over the sidebar and back doesn't refetch.
    func reloadIfCutShort() async {
        guard !hasAttemptedLoad else { return }
        await refresh()
    }

    /// Fetch + publish the folder list without walking per-folder STATUS.
    /// Split out so the parent view can seed a default selection (Inbox)
    /// the moment the sidebar arrives — the unread-count walk fans out
    /// across every folder and can take a second or two on first load,
    /// during which there's no reason to leave the user staring at an
    /// empty pane.
    func loadFolderList() async {
        isLoading = true
        // Cut short before any outcome, the load stays pending: the spinner
        // holds until the next appearance resumes it. Otherwise it settles.
        defer { if hasAttemptedLoad { isLoading = false } }
        do {
            let (all, savedBecause) = try await client.foldersForDisplay()
            if let savedBecause {
                // `foldersForDisplay` falls back on a cancelled request too
                // (`shouldQueue` takes `.cancelled`). When the cancel was this
                // task's, nothing failed: no error, no saved copy, no attempt.
                guard !Task.isCancelled else { return }
                hasAttemptedLoad = true
                errorMessage = savedBecause.localizedDescription
                // A list fetched live this session is newer than the saved
                // one, which predates any folder deleted or subscription
                // changed since: keep it, as a failed refresh always did.
                guard folders.isEmpty || isShowingSavedCopy else { return }
                await showSavedCopy(all)
                return
            }
            // A list that answered before a cancel is applied, as
            // `RulesViewModel` and the message list apply theirs.
            hasAttemptedLoad = true
            folders = sortForSidebar(all)
            // Badges seeded from a saved copy (here, or by visionOS's landing
            // model) go with it, so a recount cut short leaves them blank
            // rather than old. A no-op unless something was seeded.
            mailStore.counts.clearSeeded()
            isShowingSavedCopy = false
            // Publish the LSUB set by path so the message list's
            // unsubscribed-folder banner reads subscription from here rather
            // than from whatever `Folder` value the selection happens to hold
            // — a navigate request selects a stand-in `Folder(path:)` whose
            // flag is a default, not a fact.
            mailStore.counts.setSubscribedFolders(Set(all.filter(\.isSubscribed).map(\.path)))
            errorMessage = nil
            // Keep the Spotlight indexer's subscription gate current — it
            // also purges the index domains of folders unsubscribed or
            // deleted from another client since the last list.
            await client.spotlightIndexer?.setSubscribedFolders(
                Set(all.filter(\.isSubscribed).map(\.path))
            )
        } catch {
            // SwiftUI tearing the sidebar's `.task` down mid-request is not a
            // failure. Read off the Task alone, not the error (nor a
            // `CancellationError` check): one that isn't this task's would
            // otherwise leave the spinner up on a sidebar still on screen.
            guard !Task.isCancelled else { return }
            hasAttemptedLoad = true
            errorMessage = error.localizedDescription
        }
    }

    /// Offline: the saved list draws the sidebar, and the error stays up above
    /// it, as the message list's does over its cached rows. It stays away
    /// from the Spotlight gate, which purges folders missing from its set,
    /// and the badges start from the counts saved with it.
    private func showSavedCopy(_ all: [Folder]) async {
        folders = sortForSidebar(all)
        isShowingSavedCopy = true
        mailStore.counts.setSubscribedFolders(Set(all.filter(\.isSubscribed).map(\.path)))
        await seedSavedCounts()
    }

    /// Badges from the counts saved by the last successful STATUS (and the
    /// changes made here since), for the folders a refresh recounts (INBOX
    /// and the subscribed ones) that this session hasn't counted live.
    /// Unsubscribed folders get no badge until opened, as online. Only a
    /// reply that carried both numbers is used, as
    /// `MailSessionStore.takeStatus` requires of a live one.
    /// Seeded rather than set through `setFolderCounts`, which would also set
    /// the app badge: that shows what this device last set, which can be
    /// newer than the saved STATUS (`MailCounts.seed`).
    private func seedSavedCounts() async {
        let saved = await client.savedFolderStatuses()
        guard mailStore.acceptsCounts(from: client) else { return }
        let recounted = folders.filter { $0.isSubscribed || MailCounts.isInbox($0.path) }
        for folder in recounted {
            guard let status = saved[folder.path] else { continue }
            if mailStore.counts.seed(folderPath: folder.path, from: status) {
                mailStore.counts.savedFolderCounts.markSeeded(folder.path)
            }
        }
    }

    /// Folders the user has subscribed to. Mirrors the sort of `folders`
    /// (which already pins Inbox first, then user folders, then system
    /// folders), filtered to the subscribed subset.
    var subscribedFolders: [Folder] {
        folders.filter { $0.isSubscribed }
    }

    /// Optimistically flip the subscription state, fire the IMAP/API call,
    /// and revert on failure. Mirrors the React rail's behavior so toggling
    /// from the Apple sidebar feels as responsive as the web client.
    func toggleSubscription(_ folder: Folder) async {
        let target = !folder.isSubscribed
        applySubscription(path: folder.path, to: target)
        do {
            try await client.setSubscribed(target, path: folder.path)
            errorMessage = nil
            // Unsubscribing purges the folder from the Spotlight index;
            // subscribing admits it (indexed on next open or session sweep).
            await client.spotlightIndexer?.noteSubscription(
                folder: folder.path, isSubscribed: target
            )
        } catch {
            applySubscription(path: folder.path, to: !target)
            errorMessage = error.localizedDescription
        }
    }

    private func applySubscription(path: String, to subscribed: Bool) {
        guard let index = folders.firstIndex(where: { $0.path == path }) else { return }
        let previous = folders[index]
        folders[index] = Folder(
            path: previous.path,
            attributes: previous.attributes,
            isSubscribed: subscribed
        )
        // The selection binding still holds the pre-toggle `Folder` value;
        // the published set is what lets the open list's banner follow the
        // toggle without a re-select.
        mailStore.counts.setSubscription(folderPath: path, isSubscribed: subscribed)
    }

    // MARK: - Create / delete

    /// Create a folder (optionally nested under `parent`) and auto-subscribe
    /// it so it shows up in the sidebar without a second tap — Dovecot doesn't
    /// subscribe on create for us. The auto-subscribe is best-effort: if the
    /// server rejects the SUBSCRIBE the folder still exists and the reload
    /// below surfaces it. Reloads the full list (rather than appending) so the
    /// new folder slots into the sidebar tree sort, then back-fills counts.
    /// A failed create is thrown for the New Folder sheet to show, rather
    /// than written to `errorMessage`, which the sidebar draws behind the
    /// sheet (#1915). The sheet's Create is disabled for a blank name
    /// (`NewFolderForm.canCreate`).
    func createFolder(name: String, parent: String?) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        try await client.imapClient.createFolder(name: trimmed, parent: parent)
        try? await client.imapClient.subscribe(
            path: fullPath(for: trimmed, parent: parent)
        )
        await loadFolderList()
        await refreshSubscribedCounts()
        errorMessage = nil
    }

    /// Delete a user folder. Gated by `canDelete` so system folders and
    /// `\Noselect` containers stay protected; prunes the row on success.
    /// Returns true on success so the caller can move a selection that was
    /// pointing at the folder (the sidebar's binding is owned by the split
    /// view, not by this model).
    @discardableResult
    func deleteFolder(_ folder: Folder) async -> Bool {
        guard canDelete(folder) else { return false }
        do {
            try await client.deleteFolder(path: folder.path)
            folders.removeAll { $0.path == folder.path }
            errorMessage = nil
            // The folder's envelope-cache snapshot isn't invalidated on
            // delete (the row just disappears), so purge its Spotlight
            // domain explicitly.
            await client.spotlightIndexer?.removeFolder(folder.path)
            return true
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Folders the user can nest a new folder under. `\Noselect`
    /// (container-only) folders are excluded because a child `CREATE` would
    /// fail against them.
    var possibleParents: [Folder] {
        folders.filter { !$0.attributes.contains("\\Noselect") }
    }

    /// Folders the user is not allowed to delete: the system mailboxes and any
    /// `\Noselect` container.
    static let systemPaths: Set<String> = [
        "INBOX", "Sent", "Drafts", "Trash", "Junk", "Archive"
    ]

    func canDelete(_ folder: Folder) -> Bool {
        !Self.systemPaths.contains(folder.path)
            && !folder.attributes.contains("\\Noselect")
    }

    private func fullPath(for name: String, parent: String?) -> String {
        if let parent, !parent.isEmpty {
            return "\(parent)/\(name)"
        }
        return name
    }

    /// Permanently deletes everything in Trash. Called only after the
    /// sidebar's confirmation dialog. The after-effects (Trash's snapshot,
    /// its badge, the list reload) are the mutation service's.
    func emptyTrash() async {
        do {
            try await mailStore.mutations.emptyTrash(through: client)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Marks every unseen message in `folderPath` read, in one server call.
    /// Called only after the sidebar's confirmation dialog names the folder.
    /// The after-effects (cache drop, badge, list reload) are
    /// `FolderMarkAllRead`'s, shared with the message list's own entry.
    func markAllRead(folderPath: String) async {
        do {
            try await FolderMarkAllRead.perform(folderPath: folderPath, client: client, mailStore: mailStore)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetch the INBOX STATUS and publish it. Called as early as
    /// possible at launch so the inbox badge is correct by the time the
    /// user's eyes reach it. Safe to fire in parallel with
    /// `loadFolderList()` — they share the IMAP connection but the API-
    /// backed client serializes its own commands, so the two requests
    /// just queue.
    func refreshInboxCount() async {
        await fetchAndPublishCount(path: "INBOX")
    }

    /// Walk subscribed folders (minus INBOX, which `refreshInboxCount()`
    /// handles separately) and publish counts as they land. Runs with
    /// bounded concurrency via a task group so a mailbox with 20+
    /// subscribed folders fills in noticeably faster than the previous
    /// sequential walk.
    func refreshSubscribedCounts() async {
        await refreshCounts(of: subscribedFolders)
    }

    /// Walk *every* folder's STATUS. The one deliberate exception to
    /// "unsubscribed folders are on-demand": the sidebar's Unread pill,
    /// chosen without Subscribed, can't be honest without a count for each
    /// folder, so choosing it is the demand. `FolderListView` calls this
    /// when the pill enters that state and on each manual refresh while it
    /// stays there; the proactive paths (`refresh`, `createFolder`) keep
    /// walking the subscribed subset only.
    func refreshAllCounts() async {
        await refreshCounts(of: folders)
    }

    private func refreshCounts(of targets: [Folder]) async {
        let targets = targets
            .map(\.path)
            .filter { $0.caseInsensitiveCompare("INBOX") != .orderedSame }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var index = 0
            while index < targets.count || inFlight > 0 {
                while inFlight < subscribedRefreshConcurrency, index < targets.count {
                    let path = targets[index]
                    index += 1
                    inFlight += 1
                    group.addTask { [weak self] in
                        await self?.fetchAndPublishCount(path: path)
                    }
                }
                await group.next()
                inFlight -= 1
            }
        }
    }

    /// On-demand fetch for a single folder, intended for unsubscribed
    /// folders the user has selected (or asked to refresh via the
    /// in-pane banner). Tracks the path in `refreshingPaths` so the UI
    /// can show a spinner while the round trip is in flight.
    func refreshFolderCount(path: String) async {
        await fetchAndPublishCount(path: path)
    }

    @discardableResult
    private func fetchAndPublishCount(path: String) async -> FolderStatus? {
        refreshingPaths.insert(path)
        defer { refreshingPaths.remove(path) }
        let askedAt = ContinuousClock.now
        guard let status = try? await client.folderStatus(path: path) else {
            return nil
        }
        // A reply for a session that has started ending is the last
        // account's (#1848).
        guard mailStore.acceptsCounts(from: client) else { return status }
        // Bounded by the writes it may predate, so a reply asked before a
        // mark-read landed can't put the badge back up (#1880).
        let counts = mailStore.boundedFolderCounts(
            unread: status.unseen ?? 0, total: status.messages ?? 0, folderPath: path, askedAt: askedAt
        )
        mailStore.counts.setFolderCounts(folderPath: path, unread: counts.unread, total: counts.total)
        return status
    }

    /// Inbox first, then user folders arranged as a `/`-delimited tree
    /// (peers alphabetical, children directly under their parent), then
    /// system folders grouped at the bottom. `\Noselect` containers can't be
    /// opened, so they're dropped from the user section.
    private func sortForSidebar(_ input: [Folder]) -> [Folder] {
        FolderTree.sidebarOrder(input, dropNoselectUserFolders: true)
    }

    // Per-row indentation and the collapse chevron depend on which folders
    // the filter pills leave in the tree, so they're computed in
    // `FolderSectionRows` against that list rather than here.
}
