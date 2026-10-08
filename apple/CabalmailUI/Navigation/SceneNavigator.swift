import SwiftUI
import Observation
import CabalmailKit

/// One main window's navigation: where the window is, held above the layout
/// switch so a size-class swap rebuilds only the layout.
///
/// `SignedInRootView` owns one per window in `@State`, the lowest view that
/// survives the swap between the compact tab tree and the regular split, and
/// hands it down in the environment. The route (`AppRoute`) names the place
/// by ID; beside it the navigator keeps the resolved `Folder` and `Envelope`
/// the views still take, the compact column and tab, the sidebar's fetched
/// folders, and the launch landing's flags. Before this, all of it was
/// `@State` on `MailRootView` and went with each tree: a fold or a narrowed
/// iPad window re-landed the new tree from the per-install resume session,
/// which another window may have written since.
///
/// **Trees.** Each `MailRootView` instance is a tree with an identity of its
/// own (`mailTreeAppeared`). The first tree in a window lands — on a parked
/// navigate request, else the launch snapshot of the resume session. A tree
/// built later by a layout swap renders the window's route instead: the
/// folder stays, and an open message is re-parked through
/// `NavStateCoordinator.scheduleRestore`, so the new list selects it once it
/// has appeared and loaded. Until a tree has appeared it sees the route's
/// folder but no message, so a compact stack is never handed a list and a
/// reader in one update (#1664), and writes from any other tree — the one a
/// swap is tearing down — are dropped.
///
/// Every transition does what the `MailRootView` handler it replaced did,
/// cursor recording included. Search stays the view's (a transition that
/// reads it takes `isSearching`), and so does the wide layout's feed
/// selection, whose landing the navigator hands back as a scope to open.
@Observable
@MainActor
final class SceneNavigator {
    /// The window this navigator belongs to: `MainWindowCommandScope`'s
    /// `commandWindowID`, the identity command targeting already uses. Set
    /// by the host from the environment; nil until then.
    var windowID: UUID?

    private(set) var route: AppRoute

    /// The sidebar's folder: the resolved value of `route.mail.folderPath`,
    /// the fetched `Folder` once the folder list has loaded (#1535).
    private(set) var selectedFolder: Folder?

    /// The message open on the tree that has appeared; read through
    /// `envelope(in:)`. Usually the route's message, but a search result
    /// while searching.
    private var selectedEnvelope: Envelope?

    /// Which column the collapsed navigation shows; read through
    /// `compactColumn(in:)`. Stored rather than derived from the route
    /// because backing out to the folder list leaves the folder selected.
    private var compactColumn: NavigationSplitViewColumn = .sidebar

    /// The compact layout's tab. Seeded from the resume session when the
    /// window is created and kept from then on, so a swap to the regular
    /// split and back reopens the tab it left (#1644) — the Search,
    /// Addresses and Settings tabs included. On the wide layout, which has no
    /// tab bar, it follows the section the split shows.
    private(set) var compactTab: CompactTab

    /// The sidebar's fetched folders, so a navigate request can select the
    /// real `Folder` the sidebar tags its row with rather than a stand-in
    /// (#1535).
    private(set) var loadedFolders: [Folder] = []

    /// Whether this window has landed: on the session's folder, provisionally,
    /// in the feed reader, or on a navigate request. Never reset — a cleared
    /// selection later must not pull the user back to the landing.
    private(set) var didLand = false

    /// Set alongside a provisional landing and consumed by the folder list's
    /// first load, which swaps the fetched folder in (`foldersLoaded`).
    private(set) var awaitingLaunchReconcile = false

    private var mountedTree: UUID?
    private var mountedTreeIsWide = false

    private let coordinator: @MainActor () -> NavStateCoordinator?
    private let hasClient: @MainActor () -> Bool

    /// - Parameters:
    ///   - coordinator: the session's `NavStateCoordinator`, read live
    ///     (sign-in and sign-out replace it).
    ///   - hasClient: whether a client is wired; the landing waits for one
    ///     because the message list cannot build its model without it.
    init(
        coordinator: @escaping @MainActor () -> NavStateCoordinator?,
        hasClient: @escaping @MainActor () -> Bool
    ) {
        self.coordinator = coordinator
        self.hasClient = hasClient
        // The coordinator's section when one exists, else the stored
        // session's: a new window opens where the app last was.
        let section = coordinator()?.launchSection ?? ResumeSessionStore.storedSection() ?? .mail
        route = AppRoute(section: section)
        compactTab = CompactTab.initial(for: section)
    }

    convenience init(appState: AppState) {
        self.init(
            coordinator: { [weak appState] in appState?.navCoordinator },
            hasClient: { [weak appState] in appState?.client != nil }
        )
    }

    // MARK: Trees

    /// The open message as `tree` should draw it: none until the tree has
    /// appeared (see the type's doc).
    func envelope(in tree: UUID) -> Envelope? {
        tree == mountedTree ? selectedEnvelope : nil
    }

    /// The compact column as `tree` should draw it: until the tree has
    /// appeared, the column the route's folder alone gives.
    func compactColumn(in tree: UUID) -> NavigationSplitViewColumn {
        tree == mountedTree ? compactColumn : CompactColumnPolicy.afterFolderChange(hasFolder: selectedFolder != nil)
    }

    /// A `MailRootView` appeared. The first tree in the window lands; a tree
    /// built after it by a layout swap takes over the window's route; the
    /// same tree appearing again (a tab switch) changes nothing once the
    /// window has landed. Returns a feed scope for a wide tree to open, when
    /// that is where the window goes.
    func mailTreeAppeared(_ tree: UUID, isWide: Bool, showingFeeds: Bool) async -> RssItemScope? {
        let isRebuild = mountedTree != nil && mountedTree != tree
        mountedTree = tree
        mountedTreeIsWide = isWide
        if isRebuild, didLand { return await rehand(isWide: isWide) }
        return await landIfNeeded(isWide: isWide, showingFeeds: showingFeeds)
    }

    /// A rebuilt tree renders the route: the folder stays, an open message is
    /// parked for the new list to select after its initial load, and the
    /// compact column starts on that folder's list. The feed reader is not on
    /// the navigator yet, so a wide tree in the feeds section re-opens the
    /// session's scope, as every rebuilt tree used to.
    private func rehand(isWide: Bool) async -> RssItemScope? {
        selectedEnvelope = nil
        compactColumn = CompactColumnPolicy.afterFolderChange(hasFolder: selectedFolder != nil)
        guard let coordinator = coordinator() else { return nil }
        if let message = route.mail.message {
            coordinator.scheduleRestore(for: NavState(
                folder: message.folder, messageID: message.messageId, uid: message.uid,
                clientID: coordinator.clientID
            ))
        }
        guard isWide, route.section == .feeds else { return nil }
        return await coordinator.consumeFeedsLaunchTarget()
    }

    // MARK: Landing

    /// The launch landing (`docs/1.x/resume-session-plan.md`). A navigate
    /// request parked before this window existed — a cold launch from a
    /// tapped notification routes as soon as the session is wired, before
    /// the first render — is the landing, and pre-empts the session's.
    /// Otherwise a session that ended in the feed reader reopens its scope on
    /// the wide layout, which hosts feeds in the same split; anything else
    /// lands provisionally on the session's folder (INBOX when there is none)
    /// right away, before `/list_folders` returns, so the message list and
    /// its envelope cache start loading, with the open message scheduled for
    /// the list to reselect. The folder list's first load swaps the fetched
    /// folder in (`foldersLoaded`). Seeded as subscribed so the list doesn't
    /// flash the unsubscribed-folder banner before the real state arrives.
    private func landIfNeeded(isWide: Bool, showingFeeds: Bool) async -> RssItemScope? {
        guard let coordinator = coordinator() else { return nil }
        if let request = coordinator.navigateRequest {
            coordinator.navigateRequest = nil
            navigate(to: request)
        }
        guard !didLand, selectedFolder == nil, !showingFeeds, hasClient() else { return nil }
        didLand = true
        if isWide, coordinator.launchSection == .feeds,
           let scope = await coordinator.consumeFeedsLaunchTarget() {
            return scope
        }
        let target = coordinator.mailLaunchTarget()
        awaitingLaunchReconcile = true
        coordinator.armProvisionalLanding()
        if let restore = target.messageRestore {
            coordinator.scheduleRestore(for: restore)
        }
        setFolder(Folder(path: target.folderPath, isSubscribed: true))
        return nil
    }

    /// The folder list's first load. Finishes a provisional landing, or a
    /// launch whose client was not wired in time to land at all; otherwise
    /// swaps the fetched folder in for a same-path stand-in a navigate
    /// request selected before the list arrived (#1535).
    func foldersLoaded(_ folders: [Folder]) {
        loadedFolders = folders
        if awaitingLaunchReconcile, selectedFolder == nil {
            // The user left the provisional landing before the list arrived
            // (on iPhone, back to the folder list): finish the launch without
            // landing them again (#1912).
            awaitingLaunchReconcile = false
            coordinator()?.materializeLanding()
        } else if awaitingLaunchReconcile || (!didLand && selectedFolder == nil) {
            awaitingLaunchReconcile = false
            finishLaunchLanding(from: folders)
        } else if let current = selectedFolder,
                  let fetched = folders.first(where: { $0.path == current.path }), fetched != current {
            setFolder(fetched)
        }
    }

    /// Completes the launch landing once the folder list arrives. The
    /// fetched folder of the provisional landing's path is swapped in — same
    /// path, so the mounted list survives and nothing is re-recorded. A
    /// folder that no longer exists (deleted since the session was saved,
    /// perhaps from another device) falls back to INBOX and drops the message
    /// restore aimed at it (#1062). The landing's own server write, held back
    /// so the cross-device probe reads another install's cursor
    /// (`armProvisionalLanding`), goes out once the probe has run
    /// (`materializeLanding`).
    private func finishLaunchLanding(from folders: [Folder]) {
        let inbox = folders.first { folder in
            folder.path.caseInsensitiveCompare("INBOX") == .orderedSame
        } ?? folders.first
        let coordinator = coordinator()
        if let current = selectedFolder {
            if let fetched = folders.first(where: { $0.path == current.path }) {
                setFolder(fetched)
            } else if let inbox {
                coordinator?.clearPendingRestore()
                setFolder(inbox)
            }
        } else if let coordinator {
            // The client wasn't wired when the tree appeared, so there was no
            // provisional landing: land now.
            let target = coordinator.mailLaunchTarget()
            coordinator.armProvisionalLanding()
            if let restore = target.messageRestore {
                coordinator.scheduleRestore(for: restore)
            }
            setFolder(folders.first(where: { $0.path == target.folderPath }) ?? inbox)
        } else {
            setFolder(inbox)
        }
        coordinator?.materializeLanding()
    }

    /// The fetched `Folder` for `path` when the sidebar has loaded it, else a
    /// stand-in that the next `foldersLoaded` swaps out (#1535).
    func resolvedFolder(path: String) -> Folder {
        loadedFolders.first { $0.path == path } ?? Folder(path: path)
    }

    // MARK: Navigation

    /// Takes a cursor to this window — a tapped notification, a Spotlight
    /// result, Siri, the resume banner: schedules its message for the list
    /// to select, and moves to its folder and the Mail tab. Selecting a new
    /// folder re-mounts its list, which consumes the restore; a same-folder
    /// jump relies on the mounted list observing the new `pendingRestore`.
    func navigate(to cursor: NavState) {
        guard let coordinator = coordinator() else { return }
        coordinator.scheduleRestore(for: cursor)
        if selectedFolder?.path != cursor.folder {
            setFolder(resolvedFolder(path: cursor.folder))
        }
        didLand = true
        showTab(.mail)
    }

    /// `navigateRequest` changed: the first window to see a request takes it.
    /// It stays one app-wide slot, written by push, Spotlight and App Intents,
    /// which do not know which window should answer.
    func takeNavigateRequest() {
        guard let coordinator = coordinator(), let request = coordinator.navigateRequest else { return }
        coordinator.navigateRequest = nil
        navigate(to: request)
    }

    /// A sidebar pick, or the list's folder-switch menu. A pick of the folder
    /// already selected still comes through here, which is what lets the
    /// view end a search on it (#1217).
    func selectFolder(_ folder: Folder?) {
        setFolder(folder)
    }

    /// A feed pick on the wide layout, where feeds and mail share one split:
    /// the mail folder and message clear. Neither is recorded; the feed
    /// scope's own record moves the session to feeds.
    func showFeeds() {
        setFolder(nil)
        applyMessage(nil, isSearching: false)
        moveSection(to: .feeds)
    }

    /// The list's selection from `tree` — a tap, a restore, an advance after
    /// a dispose.
    func selectMessage(_ envelope: Envelope?, isSearching: Bool, from tree: UUID) {
        guard tree == mountedTree else { return }
        applyMessage(envelope, isSearching: isSearching)
    }

    /// The collapsed split view moved column from `tree` (the back gesture).
    /// Leaving the reader drops the open message, so the same row can be
    /// opened again.
    func setCompactColumn(_ column: NavigationSplitViewColumn, isSearching: Bool, from tree: UUID) {
        guard tree == mountedTree, column != compactColumn else { return }
        compactColumn = column
        if CompactColumnPolicy.dropsMessage(movingTo: column) {
            applyMessage(nil, isSearching: isSearching)
        }
    }

    /// The compact tab bar switched, or a navigation moved it. The Mail and
    /// Feeds tabs each keep their own position, so only the section moves;
    /// the utility tabs move nothing.
    func showTab(_ tab: CompactTab) {
        compactTab = tab
        guard let section = tab.resumeSection else { return }
        route.section = section
        coordinator()?.noteSection(section)
    }

    // MARK: Transitions

    private func setFolder(_ folder: Folder?) {
        // A same-path write is a metadata reconcile — the provisional
        // `Folder(path:)` swapped for the fetched one: same mailbox, so the
        // message stays and nothing is re-recorded.
        guard folder?.path != selectedFolder?.path else {
            if folder != selectedFolder { selectedFolder = folder }
            return
        }
        selectedFolder = folder
        selectedEnvelope = nil
        route.mail = AppRoute.Mail(folderPath: folder?.path)
        compactColumn = CompactColumnPolicy.afterFolderChange(hasFolder: folder != nil)
        guard let path = folder?.path else { return }
        moveSection(to: .mail)
        // Folder is the cursor's highest-priority field; the coordinator
        // debounces and de-dupes the write.
        coordinator()?.recordFolder(path)
    }

    private func applyMessage(_ envelope: Envelope?, isSearching: Bool) {
        guard envelope != selectedEnvelope else { return }
        selectedEnvelope = envelope
        compactColumn = CompactColumnPolicy.column(hasSelectedMessage: envelope != nil, current: compactColumn)
        // While searching, the open message is a result with no single folder
        // to anchor the cursor to.
        guard !isSearching, let folderPath = selectedFolder?.path else { return }
        guard let envelope else {
            route.mail.message = nil
            coordinator()?.recordNoMessage(folderPath: folderPath)
            return
        }
        // Anchored to the sidebar's folder: a row from another folder is not
        // this folder's position.
        let ref = envelope.ref(defaultFolder: folderPath)
        guard ref.folder == folderPath else { return }
        route.mail.message = ref
        coordinator()?.recordMessage(ref)
    }

    private func moveSection(to section: ResumeSession.Section) {
        guard route.section != section else { return }
        route.section = section
        // The wide layout has no tab bar. Its tab is the one a swap to the
        // compact layout opens on, so it follows what the split shows.
        if mountedTreeIsWide { compactTab = CompactTab.initial(for: section) }
    }
}
